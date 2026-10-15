#!/usr/bin/env python3
import csv

MAP_SIZE = 25
DEFAULT_THROTTLE_MAP = [197, 209, 222, 236, 253, 276, 304, 336, 369, 406, 444, 483, 525, 567, 612, 662, 718, 771, 816, 858, 897, 933, 966, 1000, 1023]
DEFAULT_CONF = {
    'adcMin': 195, 'adcMax': 854, 'pwmMin': 196, 'pwmMax': 1023, 'idleRPM': 50.0,
    'flyAlphaTau': 0.04, 'flywheelInertia': 4.0, 'flyKfw': 0.05,
    'flywheelGainUp': 4.0, 'flywheelGainDown': 3.0,
    'flyDeadbandRPM': 100.0, 'flySlewRecover': 350.0,
    'flyDeadbandEnabled': True, 'flySlewEnabled': True,
    'flywheelEnabled': True, 'flyGainUpEnabled': True, 'flyGainDownEnabled': True,
    'intervalPetli': 5, 'fwUpMap': [100]*25, 'fwDownMap': [100]*25, 'flywheelMaxRPM': 8000.0,
}
def interpolateMap(m, pos):
    if pos <= 0: return m[0]
    if pos >= 1: return m[-1]
    idx = pos * (len(m)-1)
    i = int(idx)
    if i >= len(m)-1: return m[-1]
    frac = idx - i
    return m[i]*(1-frac) + m[i+1]*frac
def mapFloat(x, a,b,c,d):
    if abs(b-a) < 1e-6: return c
    return (x-a)*(d-c)/(b-a)+c

class Flywheel:
    def __init__(self, conf):
        self.c = conf; self.flywheelRPM=0.0; self.lastSlewedCorr=0.0; self.averagedRPM=0.0
        self.lastAnalogValue = conf['adcMin'] + int(0.25*(conf['adcMax']-conf['adcMin']))
    def apply(self, desiredPWM, deltaTime, averagedRPM):
        c=self.c; self.averagedRPM=averagedRPM
        if not c['flywheelEnabled'] or deltaTime<0.001:
            self.flywheelRPM=averagedRPM; self.lastSlewedCorr=0.0; return desiredPWM,0,0,0
        if c['flyDeadbandEnabled'] and averagedRPM < c['flyDeadbandRPM']:
            self.flywheelRPM=averagedRPM; self.lastSlewedCorr=0.0; return desiredPWM,0,0,0
        if self.flywheelRPM<1.0: self.flywheelRPM=averagedRPM
        if self.flywheelRPM < c['idleRPM']: self.flywheelRPM=c['idleRPM']
        tau=max(0.005,min(0.8,c['flyAlphaTau']*c['flywheelInertia']))
        a=deltaTime/(tau+deltaTime); a=max(0,min(1,a))
        self.flywheelRPM=self.flywheelRPM*(1-a)+averagedRPM*a
        error=max(-3000,min(3000,self.flywheelRPM-averagedRPM))
        gasPos=max(0,min(1,mapFloat(self.lastAnalogValue,c['adcMin'],c['adcMax'],0,1)))
        throttleLow=gasPos<0.10
        if throttleLow and error<=0:
            self.flywheelRPM=averagedRPM; self.lastSlewedCorr=0.0; return desiredPWM,0,0,0
        corr=error*c['flyKfw']
        if corr<0 and not c['flyGainUpEnabled']: corr=0
        if corr>0 and not c['flyGainDownEnabled']: corr=0
        gain=c['flywheelGainUp'] if corr<0 else c['flywheelGainDown']
        corr*=gain
        rpmPos=max(0,min(1,averagedRPM/c['flywheelMaxRPM']))
        mult=interpolateMap(c['fwUpMap'] if corr<0 else c['fwDownMap'],rpmPos)
        corr*=mult*0.01
        if not c['flySlewEnabled'] or c['flySlewRecover']<=0:
            slewed=corr
        else:
            deepening=abs(corr)>=abs(self.lastSlewedCorr)+0.001
            if deepening: slewed=corr
            else:
                step=(c['pwmMax']-c['pwmMin'])*c['intervalPetli']/c['flySlewRecover']
                diff=max(-step,min(step,corr-self.lastSlewedCorr))
                slewed=self.lastSlewedCorr+diff
        self.lastSlewedCorr=slewed
        out=max(c['pwmMin'],min(c['pwmMax'],desiredPWM+slewed))
        return out,error,corr,slewed

dt=0.005; t_end=4.5; steps=int(t_end/dt)
gasPos=0.25
adc=DEFAULT_CONF['adcMin']+int(gasPos*(DEFAULT_CONF['adcMax']-DEFAULT_CONF['adcMin']))
targetPWM=interpolateMap(DEFAULT_THROTTLE_MAP,gasPos)
print(f"Gaz 1/4: ADC={adc} gasPos={gasPos} targetPWM={targetPWM:.0f}")

def avg_profile(t):
    if t<1.0: return 3000.0
    if t<2.0: return 1500.0
    if t<3.0: return 3000.0
    if t<4.0: return 1800.0
    return 2800.0

variants={'J4_K0.05':dict(DEFAULT_CONF),'J1_lekki':{**DEFAULT_CONF,'flywheelInertia':1.0},'K0.10':{**DEFAULT_CONF,'flyKfw':0.10},'FLY_OFF':{**DEFAULT_CONF,'flywheelEnabled':False},'J8_ciezki':{**DEFAULT_CONF,'flywheelInertia':8.0}}
results={}
for name,conf in variants.items():
    fw=Flywheel(conf); fw.lastAnalogValue=adc; fw.flywheelRPM=3000
    data=[]
    for i in range(steps):
        t=i*dt; avg=avg_profile(t)
        desired=targetPWM
        if conf['flywheelEnabled']:
            out,err,corr,slewed=fw.apply(desired,dt,avg)
        else:
            out=desired; err=corr=slewed=0; fw.flywheelRPM=avg
        data.append((t,avg,fw.flywheelRPM,err,corr,slewed,desired,out))
    results[name]=data

with open('build/flywheel_sim_1_4_gas.csv','w',newline='',encoding='utf-8') as f:
    w=csv.writer(f); w.writerow(['time_s','avgRPM','flyRPM','error','corr','slewedCorr','targetPWM','outPWM','variant'])
    for name,data in results.items():
        for row in data:
            w.writerow([f"{row[0]:.3f}",f"{row[1]:.0f}",f"{row[2]:.0f}",f"{row[3]:.0f}",f"{row[4]:.0f}",f"{row[5]:.0f}",f"{row[6]:.0f}",f"{row[7]:.0f}",name])
print("CSV: build/flywheel_sim_1_4_gas.csv")
# print summary at key moments
for name in ['J4_K0.05','J1_lekki','K0.10','FLY_OFF','J8_ciezki']:
    data=results[name]
    def at(t): return min(data, key=lambda r: abs(r[0]-t))
    for t in [0.95,1.01,1.10,1.50,2.01,3.01]:
        r=at(t)
        print(f"{name:12} t={r[0]:.2f} avg={r[1]:.0f} fly={r[2]:.0f} err={r[3]:.0f} corr={r[4]:.0f} slew={r[5]:.0f} out={r[7]:.0f}")
    print("---")
# also test throttleLow case
print("\nTest gaz <10% (ADC min, 0%): czy wyrownanie dziala?")
fw=Flywheel(DEFAULT_CONF); fw.lastAnalogValue=DEFAULT_CONF['adcMin']; fw.flywheelRPM=3000
for avg in [3000,1500,3000]:
    out,err,corr,slewed=fw.apply(targetPWM,dt,avg)
    print(f" throttleLow gaz0% avg={avg} fly={fw.flywheelRPM:.0f} err={err:.0f} corr={corr:.0f} out={out:.0f} (powinno wyrownac gdy err<=0, a przy spadku 1500 error>0 -> corr>0)")

print("\nTest gaz 25% <10%? Nie - kolo zawsze aktywne")
for avg in [3000,1500]:
    fw=Flywheel(DEFAULT_CONF); fw.lastAnalogValue=adc; fw.flywheelRPM=3000
    out,err,corr,slewed=fw.apply(targetPWM,dt,avg)
    print(f" gaz25% avg={avg} fly={fw.flywheelRPM:.0f} err={err:.0f} corr={corr:.0f} out={out:.0f}")
