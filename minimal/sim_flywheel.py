#!/usr/bin/env python3
# Symulacja kola zamachowego jak w minimal/minimal.ino:372 applyFlywheel
# Gaz 1/4 (25%) + nagle zmiany RPM od obciazenia

import csv
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

MAP_SIZE = 25
DEFAULT_THROTTLE_MAP = [197, 209, 222, 236, 253, 276, 304, 336, 369, 406, 444, 483, 525, 567, 612, 662, 718, 771, 816, 858, 897, 933, 966, 1000, 1023]
DEFAULT_CONF = {
    'adcMin': 195, 'adcMax': 854,
    'pwmMin': 196, 'pwmMax': 1023,
    'idleRPM': 50.0,
    'flyAlphaTau': 0.04, 'flywheelInertia': 4.0, 'flyKfw': 0.05,
    'flywheelGainUp': 4.0, 'flywheelGainDown': 3.0,
    'flyDeadbandRPM': 100.0, 'flySlewRecover': 350.0,
    'flyDeadbandEnabled': True, 'flySlewEnabled': True,
    'flywheelEnabled': True, 'flyGainUpEnabled': True, 'flyGainDownEnabled': True,
    'intervalPetli': 5,
    'fwUpMap': [100]*25, 'fwDownMap': [100]*25, 'flywheelMaxRPM': 8000.0,
}

def interpolateMap(m, pos):
    if pos <= 0: return m[0]
    if pos >= 1: return m[-1]
    idx = pos * (len(m)-1)
    i = int(idx)
    if i >= len(m)-1: return m[-1]
    frac = idx - i
    return m[i]*(1-frac) + m[i+1]*frac

def mapFloat(x, inMin, inMax, outMin, outMax):
    if abs(inMax-inMin) < 1e-6: return outMin
    return (x-inMin)*(outMax-outMin)/(inMax-inMin)+outMin

class Flywheel:
    def __init__(self, conf):
        self.c = conf
        self.flywheelRPM = 0.0
        self.lastSlewedCorr = 0.0
        self.averagedRPM = 0.0
        self.lastAnalogValue = conf['adcMin'] + int(0.25*(conf['adcMax']-conf['adcMin']))

    def apply(self, desiredPWM, deltaTime, averagedRPM):
        c = self.c
        self.averagedRPM = averagedRPM
        # deadband jak w silniku
        if not c['flywheelEnabled'] or deltaTime < 0.001:
            self.flywheelRPM = averagedRPM
            self.lastSlewedCorr = 0.0
            return desiredPWM
        if c['flyDeadbandEnabled'] and averagedRPM < c['flyDeadbandRPM']:
            self.flywheelRPM = averagedRPM
            self.lastSlewedCorr = 0.0
            return desiredPWM
        if self.flywheelRPM < 1.0: self.flywheelRPM = averagedRPM
        if self.flywheelRPM < c['idleRPM']: self.flywheelRPM = c['idleRPM']
        tau = c['flyAlphaTau'] * c['flywheelInertia']
        tau = max(0.005, min(0.8, tau))
        a = deltaTime / (tau + deltaTime)
        a = max(0.0, min(1.0, a))
        self.flywheelRPM = self.flywheelRPM*(1-a) + averagedRPM*a
        error = self.flywheelRPM - averagedRPM
        error = max(-3000.0, min(3000.0, error))
        # gaz <10% wyrownaj, spadek zawsze (minimal.ino:385)
        gasPos = max(0.0, min(1.0, mapFloat(self.lastAnalogValue, c['adcMin'], c['adcMax'], 0.0, 1.0)))
        throttleLow = gasPos < 0.10
        if throttleLow and error <= 0.0:
            self.flywheelRPM = averagedRPM
            self.lastSlewedCorr = 0.0
            return desiredPWM
        corr = error * c['flyKfw']
        if corr < 0 and not c['flyGainUpEnabled']: corr = 0
        if corr > 0 and not c['flyGainDownEnabled']: corr = 0
        gain = c['flywheelGainUp'] if corr < 0 else c['flywheelGainDown']
        corr *= gain
        # fw map mnoznik (flat 100 = 1.0)
        rpmPos = max(0.0, min(1.0, averagedRPM / c['flywheelMaxRPM']))
        mult = interpolateMap(c['fwUpMap'] if corr < 0 else c['fwDownMap'], rpmPos)
        corr *= mult * 0.01
        # slew asymetryczny
        if not c['flySlewEnabled'] or c['flySlewRecover'] <= 0:
            slewed = corr
        else:
            deepening = abs(corr) >= abs(self.lastSlewedCorr) + 0.001
            if deepening:
                slewed = corr
            else:
                step = (c['pwmMax']-c['pwmMin']) * c['intervalPetli'] / c['flySlewRecover']
                diff = corr - self.lastSlewedCorr
                diff = max(-step, min(step, diff))
                slewed = self.lastSlewedCorr + diff
        self.lastSlewedCorr = slewed
        out = desiredPWM + slewed
        out = max(c['pwmMin'], min(c['pwmMax'], out))
        return out, error, corr, slewed

# --- symulacja ---
dt = 0.005  # intervalPetli 5ms
t_end = 4.5
steps = int(t_end/dt)
# gaz 1/4
gasPos = 0.25
adc = DEFAULT_CONF['adcMin'] + int(gasPos*(DEFAULT_CONF['adcMax']-DEFAULT_CONF['adcMin']))  # ~359
targetPWM = interpolateMap(DEFAULT_THROTTLE_MAP, gasPos)  # ~304
print(f"Gaz 1/4: ADC={adc} gasPos={gasPos} targetPWM={targetPWM:.0f} (throttleMap[6]=304)")

# profil RPM od obciazenia: 0-1s 3000, 1-2s 1500 (ciezkie hamowanie), 2-3s 3000 (odciazenie), 3-4.5s 1800 (lzejsze)
def avg_profile(t):
    if t < 1.0: return 3000.0
    if t < 2.0: return 1500.0
    if t < 3.0: return 3000.0
    if t < 4.0: return 1800.0
    return 2800.0

# uruchom 4 warianty jak w planie: J=4 K0.05 (domyslny), J=1 lekki, K=0.1 mocniejszy, fly off
variants = {
    'J4_K0.05 (domyslny)': dict(DEFAULT_CONF),
    'J1_lekki': {**DEFAULT_CONF, 'flywheelInertia': 1.0},
    'K0.10_mocny': {**DEFAULT_CONF, 'flyKfw': 0.10},
    'FLY_OFF': {**DEFAULT_CONF, 'flywheelEnabled': False},
}
# dodatkowo wariant J8 ciezki dla porownania
variants['J8_ciezki'] = {**DEFAULT_CONF, 'flywheelInertia': 8.0}

results = {}
for name, conf in variants.items():
    fw = Flywheel(conf)
    fw.lastAnalogValue = adc
    # init fly
    fw.flywheelRPM = 3000
    data = []
    for i in range(steps):
        t = i*dt
        avg = avg_profile(t)
        # stopniowe przejscie avg? dla wiernosci skok natychmiastowy jak w hamulcu
        desired = targetPWM
        if conf['flywheelEnabled']:
            out, err, corr, slewed = fw.apply(desired, dt, avg)
        else:
            out = desired
            err = 0; corr=0; slewed=0
            fw.flywheelRPM = avg  # sledzi
        data.append((t, avg, fw.flywheelRPM, err, corr, slewed, desired, out))
    results[name] = data

# zapisz CSV dla domyslnego
with open('build/flywheel_sim_1_4_gas.csv','w',newline='',encoding='utf-8') as f:
    w = csv.writer(f)
    w.writerow(['time_s','avgRPM','flyRPM','error','corr','slewedCorr','targetPWM','outPWM','variant'])
    for name, data in results.items():
        for row in data:
            w.writerow([f"{row[0]:.3f}", f"{row[1]:.0f}", f"{row[2]:.0f}", f"{row[3]:.0f}", f"{row[4]:.0f}", f"{row[5]:.0f}", f"{row[6]:.0f}", f"{row[7]:.0f}", name])
print("CSV zapisano: build/flywheel_sim_1_4_gas.csv")

# wykresy
fig, axes = plt.subplots(3, 1, figsize=(12, 10), sharex=True)

# 1: avg vs fly vs PWM dla domyslnego
ax = axes[0]
data = results['J4_K0.05 (domyslny)']
ts = [r[0] for r in data]
avgs = [r[1] for r in data]
flys = [r[2] for r in data]
outs = [r[7] for r in data]
ax.plot(ts, avgs, label='avgRPM (silnik)', color='blue', linewidth=1.5)
ax.plot(ts, flys, label='flyRPM (kolo)', color='orange', linewidth=1.5, linestyle='--')
ax.set_ylabel('RPM')
ax.set_title('1/4 gazu (targetPWM~304) - RPM vs czas, skoki obciazenia', fontsize=12)
ax.legend(loc='upper right')
ax.grid(True, alpha=0.3)
# dodaj tarcze obciazenia
for x in [1.0,2.0,3.0,4.0]:
    ax.axvline(x, color='red', linestyle=':', alpha=0.5)
ax.text(0.5, 3200, '3000', fontsize=8, ha='center', color='blue')
ax.text(1.5, 1700, '1500 obc.', fontsize=8, ha='center', color='red')
ax.text(2.5, 3200, '3000 odch.', fontsize=8, ha='center', color='green')
ax.text(3.5, 2000, '1800 obc.', fontsize=8, ha='center', color='red')
ax2 = ax.twinx()
ax2.plot(ts, outs, label='outPWM', color='green', linewidth=1, alpha=0.7)
ax2.set_ylabel('PWM (196-1023)', color='green')
ax2.tick_params(axis='y', labelcolor='green')

# 2: error i corr
ax = axes[1]
errs = [r[3] for r in data]
corrs = [r[5] for r in data]
ax.plot(ts, errs, label='error = fly-avg [RPM]', color='purple', linewidth=1.2)
ax.plot(ts, corrs, label='slewedCorr [PWM]', color='red', linewidth=1.2)
ax.set_ylabel('error RPM / corr PWM')
ax.legend(loc='upper right')
ax.grid(True, alpha=0.3)
ax.axhline(0, color='black', linewidth=0.8)
for x in [1.0,2.0,3.0,4.0]:
    ax.axvline(x, color='red', linestyle=':', alpha=0.5)

# 3: porownanie outPWM dla wariantow J/K
ax = axes[2]
for name, data in results.items():
    ts = [r[0] for r in data]
    outs = [r[7] for r in data]
    style = '-' if 'domyslny' in name else '--'
    ax.plot(ts, outs, label=name, linewidth=1.5 if 'domyslny' in name else 1.0, linestyle=style)
ax.set_ylabel('outPWM')
ax.set_xlabel('czas [s]')
ax.set_ylim(190, 650)
ax.legend(loc='upper right', fontsize=8)
ax.grid(True, alpha=0.3)
for x in [1.0,2.0,3.0,4.0]:
    ax.axvline(x, color='red', linestyle=':', alpha=0.5)
ax.text(0.02, 0.95, 'targetPWM=304 (1/4 gazu), ponizej 10% logic nieaktywna (gaz 25%)', transform=ax.transAxes, fontsize=8, va='top', bbox=dict(boxstyle='round', facecolor='wheat', alpha=0.5))

plt.tight_layout()
plt.savefig('build/flywheel_sim_1_4_gas.png', dpi=150)
print("PNG zapisano: build/flywheel_sim_1_4_gas.png")
# dodatkowy zoom na pierwszy skok 0.9-1.5s
fig2, ax = plt.subplots(figsize=(10,4))
data = results['J4_K0.05 (domyslny)']
ts = [r[0] for r in data]
avgs = [r[1] for r in data]
flys = [r[2] for r in data]
outs = [r[7] for r in data]
errs = [r[3] for r in data]
mask = [(t>=0.9 and t<=1.6) for t in ts]
ax.plot([t for t,m in zip(ts,mask) if m], [v for v,m in zip(avgs,mask) if m], label='avg', color='blue', linewidth=2)
ax.plot([t for t,m in zip(ts,mask) if m], [v for v,m in zip(flys,mask) if m], label='fly', color='orange', linewidth=2)
ax2 = ax.twinx()
ax2.plot([t for t,m in zip(ts,mask) if m], [v for v,m in zip(outs,mask) if m], label='outPWM', color='green', linewidth=1.5)
ax2.plot([t for t,m in zip(ts,mask) if m], [v for v,m in zip(errs,mask) if m], label='error', color='purple', linewidth=1, linestyle='--')
ax.set_title('Zoom: skok 3000->1500 w 1.0s (1/4 gazu) - reakcja kola')
ax.set_xlabel('czas [s]')
ax.set_ylabel('RPM')
ax2.set_ylabel('PWM / error')
ax.legend(loc='upper right')
ax.grid(True, alpha=0.3)
plt.tight_layout()
plt.savefig('build/flywheel_sim_zoom.png', dpi=150)
print("PNG zoom zapisano: build/flywheel_sim_zoom.png")
