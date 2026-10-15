#!/usr/bin/env python3
# Porownanie: STARA (moze_to v1.5, bez snapa) vs NOWA (moze_new v1.6, snap + dociaganie)
# Scenariusz jak prawdziwy log bldc_log_2026-10-04_1819.csv:
#   0 -> 4500 (wkrecalnie) -> toczenie -> hamulec do 0
# Wspolna konfiguracja: J=4, TAU=0.04 (tau 0.16s), K=0.05, gainUp 4 / gainDown 3,
# slew 350ms, deadband 50, rampa 900/600/400, <10% wyrownanie + spadek zawsze.
import csv
import math
import pathlib

HERE = pathlib.Path(__file__).parent
MAP_SIZE = 25
THROTTLE_MAP = [197, 209, 222, 236, 253, 276, 304, 336, 369, 406,
                444, 483, 525, 567, 612, 662, 718, 771, 816, 858,
                897, 933, 966, 1000, 1023]
RAMP_MAP = [900] * 7 + [600] * 6 + [400] * 12
CONF = {
    'adcMin': 195, 'adcMax': 854, 'pwmMin': 196, 'pwmMax': 1023, 'idleRPM': 50.0,
    'flyAlphaTau': 0.04, 'flywheelInertia': 4.0, 'flyKfw': 0.05,
    'flywheelGainUp': 4.0, 'flywheelGainDown': 3.0,
    'flyDeadbandRPM': 50.0, 'flySlewRecover': 350.0,
    'flyDeadbandEnabled': True, 'flySlewEnabled': True,
    'flywheelEnabled': True, 'flyGainUpEnabled': True, 'flyGainDownEnabled': True,
    'intervalPetli': 5, 'fwUpMap': [100] * 25, 'fwDownMap': [100] * 25,
    'flywheelMaxRPM': 8000.0,
}


def clamp(x, a, b):
    return a if x < a else (b if x > b else x)


def map_float(x, a, b, c, d):
    if abs(b - a) < 1e-6:
        return c
    return (x - a) * (d - c) / (b - a) + c


def interp(m, pos):
    if pos <= 0:
        return m[0]
    if pos >= 1:
        return m[-1]
    idx = pos * (len(m) - 1)
    i = int(idx)
    if i >= len(m) - 1:
        return m[-1]
    f = idx - i
    return m[i] * (1 - f) + m[i + 1] * f


class Flywheel:
    """Wspolna baza; snap=False -> v1.5 (moze_to), snap=True -> v1.6 (moze_new)."""
    def __init__(self, conf, snap):
        self.c = conf
        self.snap = snap
        self.fly = 0.0
        self.slew = 0.0
        self.prev_err = 0.0
        self.avg = 0.0
        self.last_adc = conf['adcMin']
        self.target = float(conf['pwmMin'])

    def read_throttle(self, gas_pos):
        c = self.c
        adc = int(c['adcMin'] + gas_pos * (c['adcMax'] - c['adcMin']))
        adc = clamp(adc, c['adcMin'], c['adcMax'])
        new_target = interp(THROTTLE_MAP, clamp(map_float(adc, c['adcMin'], c['adcMax'], 0, 1), 0, 1))
        if new_target > self.target:
            gp = clamp(map_float(adc, c['adcMin'], c['adcMax'], 0, 1), 0, 1)
            ramp_ms = float(interp(RAMP_MAP, gp))
            if ramp_ms <= 0:
                self.target = new_target
            else:
                step = (c['pwmMax'] - c['pwmMin']) * c['intervalPetli'] / ramp_ms
                self.target = self.target + step if new_target - self.target > step else new_target
        else:
            self.target = new_target
        self.last_adc = adc
        return self.target

    def apply(self, desired, dt, avg):
        c = self.c
        self.avg = avg
        if (not c['flywheelEnabled']) or dt < 0.001:
            self.fly, self.slew = avg, 0.0
            return desired, 0.0, 0.0, 0.0
        if c['flyDeadbandEnabled'] and avg < c['flyDeadbandRPM']:
            self.fly, self.slew = avg, 0.0
            if self.snap:
                self.prev_err = 0.0
            return desired, 0.0, 0.0, 0.0
        if self.fly < 1.0:
            self.fly = avg
        if self.fly < c['idleRPM']:
            self.fly = c['idleRPM']
        tau = clamp(c['flyAlphaTau'] * c['flywheelInertia'], 0.005, 0.8)
        a = clamp(dt / (tau + dt), 0.0, 1.0)
        self.fly = self.fly * (1 - a) + avg * a
        error = clamp(self.fly - avg, -3000.0, 3000.0)
        # --- NOWOSC v1.6 (moze_new.ino:384-397) ---
        if self.snap:
            if (self.prev_err > 5.0 and error < -5.0) or (self.prev_err < -5.0 and error > 5.0):
                self.fly, self.slew, self.prev_err = avg, 0.0, 0.0
                return desired, 0.0, 0.0, 0.0
            self.prev_err = error
            if abs(error) < 20.0:
                self.fly += (avg - self.fly) * 0.5
        # --- wspolne: <10% wyrownanie, spadek zawsze ---
        gas = clamp(map_float(self.last_adc, c['adcMin'], c['adcMax'], 0, 1), 0, 1)
        if gas < 0.10 and error <= 0.0:
            self.fly, self.slew = avg, 0.0
            if self.snap:
                self.prev_err = 0.0
            return desired, 0.0, 0.0, 0.0
        corr = error * c['flyKfw']
        if corr < 0 and not c['flyGainUpEnabled']:
            corr = 0
        if corr > 0 and not c['flyGainDownEnabled']:
            corr = 0
        corr *= c['flywheelGainUp'] if corr < 0 else c['flywheelGainDown']
        rpm_pos = clamp(avg / c['flywheelMaxRPM'], 0, 1)
        corr *= interp(c['fwUpMap'] if corr < 0 else c['fwDownMap'], rpm_pos) * 0.01
        if (not c['flySlewEnabled']) or c['flySlewRecover'] <= 0:
            slewed = corr
        else:
            if abs(corr) >= abs(self.slew) + 0.001:
                slewed = corr
            else:
                step = (c['pwmMax'] - c['pwmMin']) * c['intervalPetli'] / c['flySlewRecover']
                slewed = self.slew + clamp(corr - self.slew, -step, step)
        self.slew = slewed
        return clamp(desired + slewed, c['pwmMin'], c['pwmMax']), error, corr, slewed


def gas_profile(t):
    if t < 1.0:
        return 0.0
    if t < 3.2:
        return 0.25
    return 0.0


def avg_profile(t):
    if t < 1.0:
        return 50.0
    if t < 3.2:
        u = (t - 1.0) / 2.2
        s = u * u * (3 - 2 * u)  # smoothstep jak wkrecalnie 1278->3396 w logu
        return 50.0 + (4500.0 - 50.0) * s
    if t < 5.0:
        return 800.0 + (4500.0 - 800.0) * math.exp(-(t - 3.2) / 0.7)  # toczenie
    if t < 5.5:
        u = (t - 5.0) / 0.5
        return 1083.0 + (50.0 - 1083.0) * u  # hamulec
    return 50.0


def run(name, snap):
    fw = Flywheel(CONF, snap)
    fw.fly = 50.0
    dt, steps = 0.005, int(7.0 / 0.005)
    rows = []
    for i in range(steps):
        t = i * dt
        tgt = fw.read_throttle(gas_profile(t))
        avg = avg_profile(t)
        out, err, corr, slew = fw.apply(tgt, dt, avg)
        rows.append((t, avg, gas_profile(t), tgt, fw.fly, err, corr, slew, out))
    return rows


def metrics(rows):
    corr = [r[6] for r in rows]
    slew = [r[7] for r in rows]
    out = [r[8] for r in rows]
    rev = [r[7] for r in rows if 3.2 <= r[0] <= 4.0]  # garb wsteczny po nawrocie
    tail = [r[7] for r in rows if r[0] >= 5.5 and abs(r[7]) >= 5.0]
    settle = None
    for r in rows:
        if r[0] >= 5.5 and abs(r[7]) < 5.0:
            # stabilne? sprawdz kolejne 0.2 s
            j = rows.index(r)
            if all(abs(q[7]) < 5.0 for q in rows[j:j + 40]):
                settle = r[0]
                break
    return {
        'peak_up': max(corr), 'peak_down': min(corr),
        'rev_hump': min(rev), 'settle': settle,
        'tail_mean': sum(abs(x) for x in tail) / len(tail) if tail else 0.0,
    }


old = run('v15-moze_to', False)
new = run('v16-moze_new', True)
m_old, m_new = metrics(old), metrics(new)

with open(HERE / 'flywheel_compare_v15_v16.csv', 'w', newline='', encoding='utf-8') as f:
    w = csv.writer(f)
    w.writerow(['time_s', 'avgRPM', 'gas', 'targetPWM',
                'fly_old', 'err_old', 'corr_old', 'slew_old', 'out_old',
                'fly_new', 'err_new', 'corr_new', 'slew_new', 'out_new'])
    for ro, rn in zip(old, new):
        w.writerow(['%.3f' % ro[0], '%.0f' % ro[1], '%.2f' % ro[2], '%.0f' % ro[3],
                    '%.0f' % ro[4], '%.0f' % ro[5], '%.0f' % ro[6], '%.0f' % ro[7], '%.0f' % ro[8],
                    '%.0f' % rn[4], '%.0f' % rn[5], '%.0f' % rn[6], '%.0f' % rn[7], '%.0f' % rn[8]])
print('CSV: flywheel_compare_v15_v16.csv (%d wierszy x2 wersje)' % len(old))
for k in ('peak_up', 'peak_down', 'rev_hump', 'settle', 'tail_mean'):
    print('  %-10s old=%s new=%s' % (k, m_old[k], m_new[k]))

# --- HTML z wbudowanym CSV ---
csv_text = (HERE / 'flywheel_compare_v15_v16.csv').read_text(encoding='utf-8').replace('`', '\\`')
def fmt(v):
    return ('%.1f' % v) if isinstance(v, float) else str(v)
rows_html = ''.join(
    '<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>' % (
        k, fmt(m_old[k]), fmt(m_new[k]),
        'TAK - identyczna' if k in ('peak_up', 'peak_down') and m_old[k] == m_new[k] else (
            'zniknal' if k == 'rev_hump' and m_new[k] == 0 else (
                'szybciej' if k == 'settle' and (m_new[k] or 99) < (m_old[k] or 99) else 'porownaj wykres')),
        {  'peak_up': 'maks. corr przy hamowaniu',
           'peak_down': 'maks. ciecie przy wkrecalnie',
           'rev_hump': 'min slew w 3.2-4.0 s (garb wsteczny)',
           'settle': 'czas wygaszenia corr po stop (>5.5 s)',
           'tail_mean': 'sredni |slew| w ogonie po stop',
        }[k])
    for k in ('peak_up', 'peak_down', 'rev_hump', 'settle', 'tail_mean'))

html = '''<!DOCTYPE html>
<html lang="pl"><head><meta charset="UTF-8">
<title>Porownanie v1.5 (moze_to) vs v1.6 (moze_new)</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.0/dist/chart.umd.min.js"></script>
<style>body{font-family:system-ui,sans-serif;margin:0;background:#0f1115;color:#e6e6e6}
header{padding:14px 20px;background:#151821;border-bottom:1px solid #222}
.wrap{padding:14px 20px;max-width:1200px;margin:0 auto}
.card{background:#151821;border:1px solid #222;border-radius:12px;padding:14px;margin-bottom:14px}
table{border-collapse:collapse;width:100%;font-size:12px}
th,td{border:1px solid #2a2f3a;padding:6px 8px;text-align:right}
th{background:#1a1e27}td:first-child,th:first-child{text-align:left}
.legend{font-size:11px;color:#9aa0aa}</style></head><body>
<header><h3 style="margin:0">v1.5 moze_to (bez snapa) vs v1.6 moze_new (snap + dociaganie)
<span style="font-weight:400;color:#9aa0aa"> — scenariusz 0&rarr;4500&rarr;toczenie&rarr;hamulec do 0, J=4 K=0.05</span></h3></header>
<div class="wrap">
<div class="card"><canvas id="c1" height="130"></canvas></div>
<div class="card"><canvas id="c2" height="130"></canvas></div>
<div class="card"><canvas id="c3" height="130"></canvas></div>
<div class="card"><h3 style="margin:0 0 8px">Metryki</h3>
<table><thead><tr><th>metryka</th><th>v1.5 stara</th><th>v1.6 nowa</th><th>werdykt</th><th>opis</th></tr></thead>
<tbody>''' + rows_html + '''</tbody></table>
<p class="legend">Niebieski = avgRPM (silnik), pomarancz = fly stara, zielen = fly nowa.
Snap: zmiana znaku errora poza &plusmn;5 RPM &rarr; fly=avg, corr=0. Dociaganie: |error|&lt;20 &rarr; fly 50% do avg.
Plik CSV: flywheel_compare_v15_v16.csv (14 kolumn).</p></div></div>
<script>
let csv=`''' + csv_text + '''`;
let lines=csv.trim().split('\\n'), T=[],A=[],Fo=[],Fn=[],Eo=[],En=[],So=[],Sn=[],Oo=[],On=[];
for(let i=1;i<lines.length;i++){let p=lines[i].split(',');if(p.length<14)continue;
T.push(+p[0]);A.push(+p[1]);Fo.push(+p[4]);Eo.push(+p[5]);So.push(+p[7]);Oo.push(+p[8]);
Fn.push(+p[9]);En.push(+p[10]);Sn.push(+p[12]);On.push(+p[13]);}
let L=T.map(t=>t.toFixed(1));
let dec=i=>i%2===0, F=a=>a.filter((_,i)=>dec(i)), LT=L.filter((_,i)=>dec(i));
function mk(id,cfg){new Chart(document.getElementById(id),{type:'line',
data:{labels:LT,datasets:cfg},options:{responsive:true,interaction:{mode:'index',intersect:false},
scales:{x:{ticks:{maxTicksLimit:14}}}}});}
let thin={pointRadius:0,borderWidth:1.2,tension:0.2};
mk('c1',[{label:'avgRPM',data:F(A),borderColor:'#4a90ff',...thin,borderWidth:1.6},
{label:'fly v1.5',data:F(Fo),borderColor:'#ff8c00',borderDash:[5,3],...thin},
{label:'fly v1.6',data:F(Fn),borderColor:'#2ecc71',...thin}]);
mk('c2',[{label:'err v1.5',data:F(Eo),borderColor:'#ff8c00',borderDash:[5,3],...thin},
{label:'err v1.6',data:F(En),borderColor:'#2ecc71',...thin}]);
mk('c3',[{label:'out v1.5',data:F(Oo),borderColor:'#ff8c00',borderDash:[5,3],...thin},
{label:'out v1.6',data:F(On),borderColor:'#2ecc71',...thin}]);
</script></body></html>'''
(HERE / 'flywheel_compare_v15_v16.html').write_text(html, encoding='utf-8')
print('HTML: flywheel_compare_v15_v16.html')
