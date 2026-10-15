// MOZE_NEW v1.6-eq - jak moze_to v1.5 + wyrownanie fly=avg przy zmianie znaku errora i dociaganie w strefie malej
// Kopia moze_to (dziala w miare dobrze, nie ruszana), build osobny F:\opencode3\final_flywheel\moze_new\build
// Wirtualne kolo: flywheelRPM podaza za avg z tau=J*flyAlphaTau, <10% wyrownanie spadek zawsze

#define MAP_SIZE 25

struct Config {
  uint16_t magic;
  uint8_t  paryBiegunow;
  uint16_t filtrHalla;
  uint8_t  intervalPetli;
  uint16_t adcMin;
  uint16_t adcMax;
  uint16_t pwmMin;
  uint16_t pwmMax;
  uint16_t clutchMap[MAP_SIZE];
  uint16_t clutchAdcMin;
  uint16_t clutchAdcMax;
  bool     clutchEnabled;
  uint16_t throttleMap[MAP_SIZE];
  bool     throttleMapEnabled;
  uint16_t fwUpMap[MAP_SIZE];
  uint16_t fwDownMap[MAP_SIZE];
  bool     flywheelEnabled;
  bool     flyGainUpEnabled;
  bool     flyGainDownEnabled;
  float    flywheelInertia;
  float    flywheelMaxRPM;
  float    flywheelGainUp;
  float    flywheelGainDown;
  float    idleRPM;
  bool     flyDeadbandEnabled;
  float    flyDeadbandRPM;
  bool     flySlewEnabled;
  float    flySlewRecover;
  uint16_t rampMap[MAP_SIZE];
  float    rpmAlpha;
  float    flyAlphaTau;
  float    flyKfw;
  uint32_t checksum;
};

#define CONFIG_MAGIC 0xBEA8
#define CONFIG_MAGIC_OLD 0xBEA7
#define VERSION      "1.6-moze_new-eq-2026-09-24"

#include <EEPROM.h>
#include <avr/wdt.h>
#include <string.h>

void calibrateThrottle();
void calibrateClutch();
void resetConfig();
void saveConfigNow();

const int PWM_PIN       = 9;   // OC1A
const int ANALOG_INPUT  = A0;
const int HALL_SENSOR   = 4;   // PD4 PCINT20
const int HALL_SENSOR_2 = 5;   // PD5 PCINT21
const int HALL_SENSOR_3 = 6;   // PD6 PCINT22
const int CLUTCH_INPUT  = A2;
const uint8_t HALL_PIN_MASK = _BV(PD4) | _BV(PD5) | _BV(PD6);

Stream* activeOut = nullptr;
Stream* logOut = nullptr;

const unsigned int  EEPROM_ADDRESS       = 0U;
const unsigned long CONFIG_SAVE_DELAY_MS = 2000UL;

const uint16_t DEFAULT_CLUTCH_MAP[MAP_SIZE] = {
  1023, 965, 906, 848, 789, 730, 672, 642, 555, 496,
  437, 401, 364, 334, 310, 286, 266, 246, 230, 217,
  205, 203, 200, 198, 195
};
const uint16_t DEFAULT_THROTTLE_MAP[MAP_SIZE] = {
  197, 209, 222, 236, 253, 276, 304, 336, 369, 406,
  444, 483, 525, 567, 612, 662, 718, 771, 816, 858,
  897, 933, 966, 1000, 1023
};
const uint16_t DEFAULT_FWUP_MAP[MAP_SIZE] = {
  100, 100, 100, 100, 100,
  100, 100, 100, 100, 100,
  100, 100, 100, 100, 100,
  100, 100, 100, 100, 100,
  100, 100, 100, 100, 100
};
const uint16_t DEFAULT_FWDOWN_MAP[MAP_SIZE] = {
  100, 100, 100, 100, 100,
  100, 100, 100, 100, 100,
  100, 100, 100, 100, 100,
  100, 100, 100, 100, 100,
  100, 100, 100, 100, 100
};
const uint16_t DEFAULT_RAMP_MAP[MAP_SIZE] = {
  900, 900, 900, 900, 900, 900, 900, // 0-25% 900ms wolny start na podniesionym
  600, 600, 600, 600, 600, 600,      // 25-50% 600ms
  400, 400, 400, 400, 400, 400, 400, 400, 400, 400, 400, 400 // 50-100% 400ms żwawo
};

const Config DEFAULT_CONFIG = {
  CONFIG_MAGIC,
  5,          // paryBiegunow
  100,        // filtrHalla
  5,          // intervalPetli
  195, 854,   // adcMin, adcMax
  196, 1023,  // pwmMin, pwmMax
  {0},        // clutchMap
  179, 683,   // clutchAdcMin, clutchAdcMax
  true,       // clutchEnabled
  {0},        // throttleMap
  true,       // throttleMapEnabled
  {0},        // fwUpMap
  {0},        // fwDownMap
  true,       // flywheelEnabled
  true,       // flyGainUpEnabled
  true,       // flyGainDownEnabled
  4.0f,       // flywheelInertia
  8000.0f,    // flywheelMaxRPM
  4.0f,       // flywheelGainUp
  3.0f,       // flywheelGainDown
  50.0f,      // idleRPM
  true,       // flyDeadbandEnabled
  50.0f,      // flyDeadbandRPM - od idle, flywheel od 50 hamuje skok
  true,       // flySlewEnabled
  350.0f,     // flySlewRecover
  {0},        // rampMap
  0.06f,      // rpmAlpha
  0.04f,      // flyAlphaTau
  0.05f,      // flyKfw
  0           // checksum
};

Config config;

volatile unsigned long lastHallTime = 0;
volatile unsigned long hallPeriod   = 0;
volatile bool          newHallPulse = false;
volatile unsigned long hallFilterUs = 100UL;
volatile unsigned long hallLastTime[3]   = {0, 0, 0};
volatile unsigned long hallLastPeriod[3] = {0, 0, 0};
volatile uint8_t       lastHallPins      = 0;

float        currentRPM    = 0.0f;
float        averagedRPM   = 0.0f;
float        targetPWM     = 0.0f;
float        flywheelRPM     = 0.0f;
float        lastSlewedCorr  = 0.0f;
int          lastAnalogValue    = 0;
int          lastAnalogValueRaw = 0;
uint8_t      lastClutchPercent  = 0;
int          lastCalculatedPwm  = 0;
bool         clutchUnlocked     = false;
uint8_t      clutchUnlockCount  = 0;
bool         configDirty      = false;
unsigned long lastConfigChange = 0;
unsigned long lastLoopTime     = 0;
bool          logMode          = false;
unsigned long logStartTime     = 0;

bool          testMode        = false;
uint16_t      testAdc         = 400;
uint8_t       testPhase       = 1;
unsigned long testPhaseStart  = 0;
int           testCycleCount  = 0;
const unsigned long TEST_HOLD_MS    = 3000UL;
const int           TEST_MAX_CYCLES = 6;

uint16_t getTestAdc() {
  return (testPhase == 0) ? testAdc : config.adcMin;
}
void updateTestMode(unsigned long currentTime) {
  if (!testMode) return;
  if (testPhaseStart == 0) testPhaseStart = currentTime;
  if (currentTime - testPhaseStart >= TEST_HOLD_MS) {
    testPhase = 1 - testPhase;
    testPhaseStart = currentTime;
    if (testPhase == 0) testCycleCount++;
  }
  if (testCycleCount >= TEST_MAX_CYCLES) {
    Stream* out = logOut ? logOut : activeOut;
    testMode       = false;
    logMode        = false;
    logOut         = nullptr;
    testPhase      = 1;
    testPhaseStart = 0;
    testCycleCount = 0;
    out->println(F("testdone"));
  }
}

float mapFloat(float x, float inMin, float inMax, float outMin, float outMax) {
  if (fabsf(inMax - inMin) < 0.001f) return outMin;
  return (x - inMin) * (outMax - outMin) / (inMax - inMin) + outMin;
}
uint16_t interpolateMap(const uint16_t map[], float pos) {
  if (isnan(pos) || !isfinite(pos)) return map[0];
  if (pos <= 0.0f) return map[0];
  if (pos >= 1.0f) return map[MAP_SIZE - 1];
  float idx  = pos * (float)(MAP_SIZE - 1);
  int   i    = (int)idx;
  if (i >= MAP_SIZE - 1) return map[MAP_SIZE - 1];
  float frac = idx - i;
  return (uint16_t)(map[i] * (1.0f - frac) + map[i + 1] * frac + 0.5f);
}

uint32_t calculateChecksum(const Config& cfg) {
  uint32_t       sum  = 0;
  const uint8_t* data = (const uint8_t*)&cfg;
  for (size_t i = 0; i < sizeof(Config) - sizeof(uint32_t); i++)
    sum += data[i];
  return sum;
}
void saveConfigNow() {
  config.checksum = calculateChecksum(config);
  EEPROM.put(EEPROM_ADDRESS, config);
  configDirty = false;
}
void markConfigDirty() {
  configDirty      = true;
  lastConfigChange = millis();
}
void flushConfig() {
  if (configDirty && (millis() - lastConfigChange >= CONFIG_SAVE_DELAY_MS))
    saveConfigNow();
}
void loadConfig() {
  EEPROM.get(EEPROM_ADDRESS, config);
  uint32_t calc = calculateChecksum(config);
  if (config.magic == CONFIG_MAGIC_OLD) {
    bool looksValid = (config.paryBiegunow >= 1 && config.paryBiegunow <= 20);
    if (looksValid) {
      config.flyKfw = 0.05f;
      config.magic = CONFIG_MAGIC;
      config.checksum = calculateChecksum(config);
      saveConfigNow();
      noInterrupts(); hallFilterUs = config.filtrHalla; interrupts();
      return;
    }
  }
  if (config.magic != CONFIG_MAGIC || config.checksum != calc) {
    config = DEFAULT_CONFIG;
    memcpy(config.clutchMap,   DEFAULT_CLUTCH_MAP,   sizeof(config.clutchMap));
    memcpy(config.throttleMap, DEFAULT_THROTTLE_MAP, sizeof(config.throttleMap));
    memcpy(config.fwUpMap,     DEFAULT_FWUP_MAP,     sizeof(config.fwUpMap));
    memcpy(config.fwDownMap,   DEFAULT_FWDOWN_MAP,   sizeof(config.fwDownMap));
    memcpy(config.rampMap,     DEFAULT_RAMP_MAP,     sizeof(config.rampMap));
    saveConfigNow();
    return;
  }
  if (config.paryBiegunow == 0 || config.paryBiegunow > 20)
    config.paryBiegunow = 5;
  bool clutchMapValid   = false;
  bool throttleMapValid = false;
  bool fwUpMapValid     = false;
  bool fwDownMapValid   = false;
  bool rampMapValid     = false;
  for (int i = 0; i < MAP_SIZE; i++) {
    if (config.clutchMap[i]   != 0 && config.clutchMap[i]   != 0xFFFF) clutchMapValid   = true;
    if (config.throttleMap[i] != 0 && config.throttleMap[i] != 0xFFFF) throttleMapValid = true;
    if (config.fwUpMap[i]     != 0 && config.fwUpMap[i]     != 0xFFFF) fwUpMapValid     = true;
    if (config.fwDownMap[i]   != 0 && config.fwDownMap[i]   != 0xFFFF) fwDownMapValid   = true;
    if (config.rampMap[i]     != 0 && config.rampMap[i]     != 0xFFFF) rampMapValid     = true;
  }
  if (!clutchMapValid || config.clutchAdcMin == 0 || config.clutchAdcMax == 0) {
    memcpy(config.clutchMap, DEFAULT_CLUTCH_MAP, sizeof(config.clutchMap));
    config.clutchAdcMin  = DEFAULT_CONFIG.clutchAdcMin;
    config.clutchAdcMax  = DEFAULT_CONFIG.clutchAdcMax;
    config.clutchEnabled = DEFAULT_CONFIG.clutchEnabled;
  }
  if (!throttleMapValid) {
    memcpy(config.throttleMap, DEFAULT_THROTTLE_MAP, sizeof(config.throttleMap));
    config.throttleMapEnabled = DEFAULT_CONFIG.throttleMapEnabled;
  }
  if (!fwUpMapValid) memcpy(config.fwUpMap, DEFAULT_FWUP_MAP, sizeof(config.fwUpMap));
  if (!fwDownMapValid) memcpy(config.fwDownMap, DEFAULT_FWDOWN_MAP, sizeof(config.fwDownMap));
  if (!rampMapValid) memcpy(config.rampMap, DEFAULT_RAMP_MAP, sizeof(config.rampMap));
  if (config.pwmMin >= config.pwmMax) { config.pwmMin = DEFAULT_CONFIG.pwmMin; config.pwmMax = DEFAULT_CONFIG.pwmMax; }
  if (config.adcMin >= config.adcMax) { config.adcMin = DEFAULT_CONFIG.adcMin; config.adcMax = DEFAULT_CONFIG.adcMax; }
  if (config.idleRPM < 50.0f || config.idleRPM > 1000.0f) config.idleRPM = DEFAULT_CONFIG.idleRPM;
  if (config.flyDeadbandRPM < 0.0f || config.flyDeadbandRPM > 5000.0f) config.flyDeadbandRPM = DEFAULT_CONFIG.flyDeadbandRPM;
  if (config.flywheelInertia < 0.1f || config.flywheelInertia > 10.0f) config.flywheelInertia = DEFAULT_CONFIG.flywheelInertia;
  if (config.flywheelMaxRPM < 1000.0f || config.flywheelMaxRPM > 50000.0f) config.flywheelMaxRPM = DEFAULT_CONFIG.flywheelMaxRPM;
  if (config.flywheelGainUp < 0.1f || config.flywheelGainUp > 30.0f) config.flywheelGainUp = DEFAULT_CONFIG.flywheelGainUp;
  if (config.flywheelGainDown < 0.1f || config.flywheelGainDown > 30.0f) config.flywheelGainDown = DEFAULT_CONFIG.flywheelGainDown;
  if (config.filtrHalla < 50 || config.filtrHalla > 5000) config.filtrHalla = DEFAULT_CONFIG.filtrHalla;
  if (config.intervalPetli < 2 || config.intervalPetli > 100) config.intervalPetli = DEFAULT_CONFIG.intervalPetli;
  if (config.flySlewRecover < 0.0f || config.flySlewRecover > 2000.0f) config.flySlewRecover = DEFAULT_CONFIG.flySlewRecover;
  if (config.flySlewRecover <= 0.0f) config.flySlewEnabled = false;
  if (config.rpmAlpha < 0.05f || config.rpmAlpha > 1.0f) config.rpmAlpha = DEFAULT_CONFIG.rpmAlpha;
  if (config.flyAlphaTau < 0.005f || config.flyAlphaTau > 0.5f) config.flyAlphaTau = DEFAULT_CONFIG.flyAlphaTau;
  if (config.flyKfw < 0.01f || config.flyKfw > 0.2f) config.flyKfw = DEFAULT_CONFIG.flyKfw;
  noInterrupts(); hallFilterUs = config.filtrHalla; interrupts();
}
void resetConfig() {
  config = DEFAULT_CONFIG;
  memcpy(config.clutchMap,   DEFAULT_CLUTCH_MAP,   sizeof(config.clutchMap));
  memcpy(config.throttleMap, DEFAULT_THROTTLE_MAP, sizeof(config.throttleMap));
  memcpy(config.fwUpMap,     DEFAULT_FWUP_MAP,     sizeof(config.fwUpMap));
  memcpy(config.fwDownMap,   DEFAULT_FWDOWN_MAP,   sizeof(config.fwDownMap));
  memcpy(config.rampMap,     DEFAULT_RAMP_MAP,     sizeof(config.rampMap));
  saveConfigNow();
  activeOut->println(F("OK"));
}

uint16_t getThrottlePWM(int adcValue) {
  if (!config.throttleMapEnabled) {
    if (adcValue <= (int)config.adcMin) return config.pwmMin;
    if (adcValue >= (int)config.adcMax) return config.pwmMax;
    return (uint16_t)mapFloat(adcValue, config.adcMin, config.adcMax, config.pwmMin, config.pwmMax);
  }
  float pos = constrain(mapFloat(adcValue, config.adcMin, config.adcMax, 0.0f, 1.0f), 0.0f, 1.0f);
  return interpolateMap(config.throttleMap, pos);
}

void updateClutch() {
  static unsigned long clutchUnlockStart = 0;
  if (!clutchUnlocked) {
    if (testMode || !config.clutchEnabled) {
      clutchUnlocked = true;
    } else {
      int range   = (int)config.clutchAdcMax - (int)config.clutchAdcMin;
      int clutchRaw = analogRead(CLUTCH_INPUT);
      bool pressed = (range >= 300) && (clutchRaw >= (int)config.clutchAdcMin + range * 2 / 3);
      int tRange  = (int)config.adcMax - (int)config.adcMin;
      int thrRaw  = analogRead(ANALOG_INPUT);
      bool neutral = (thrRaw < (int)config.adcMin + tRange / 10);
      if (pressed && neutral) {
        if (clutchUnlockStart == 0) clutchUnlockStart = millis();
        if (millis() - clutchUnlockStart >= 50) clutchUnlocked = true;
      } else {
        clutchUnlockStart = 0;
        clutchUnlockCount = 0;
        OCR1A = 0;
        return;
      }
    }
  }
  if (config.clutchEnabled) {
    int clutchAdc = constrain(analogRead(CLUTCH_INPUT), (int)config.clutchAdcMin, (int)config.clutchAdcMax);
    float    pos      = constrain(mapFloat(clutchAdc, config.clutchAdcMin, config.clutchAdcMax, 0.0f, 1.0f), 0.0f, 1.0f);
    uint16_t clutchPwm = interpolateMap(config.clutchMap, pos);
    lastClutchPercent  = (uint8_t)((clutchPwm * 100UL) / 1023);
    OCR1A = min(lastCalculatedPwm, (int)clutchPwm);
  } else {
    lastClutchPercent = 100;
    OCR1A = lastCalculatedPwm;
  }
}

int readThrottle() {
  int raw = testMode ? (int)getTestAdc() : analogRead(ANALOG_INPUT);
  int adc = raw;
  if ((uint16_t)adc < config.adcMin) adc = config.adcMin;
  if ((uint16_t)adc > config.adcMax) adc = config.adcMax;
  float newTarget = getThrottlePWM(adc);
  if (newTarget > targetPWM) {
    float gasPos = constrain(mapFloat(adc, config.adcMin, config.adcMax, 0.0f, 1.0f), 0.0f, 1.0f);
    float rampMs = (float)interpolateMap(config.rampMap, gasPos);
    if (rampMs <= 0.0f) targetPWM = newTarget;
    else {
      float rampStep = (float)((int)config.pwmMax - (int)config.pwmMin) * (float)config.intervalPetli / rampMs;
      if (newTarget - targetPWM > rampStep) targetPWM += rampStep;
      else targetPWM = newTarget;
    }
  } else targetPWM = newTarget;
  lastAnalogValueRaw = raw;
  lastAnalogValue    = adc;
  return adc;
}

float applyFlywheel(float desiredPWM, float deltaTime) {
  if (!config.flywheelEnabled || deltaTime < 0.001f) { flywheelRPM = averagedRPM; lastSlewedCorr = 0.0f; return desiredPWM; }
  if (config.flyDeadbandEnabled && averagedRPM < config.flyDeadbandRPM) { flywheelRPM = averagedRPM; lastSlewedCorr = 0.0f; return desiredPWM; }
  if (flywheelRPM < 1.0f) flywheelRPM = averagedRPM;
  if (flywheelRPM < config.idleRPM) flywheelRPM = config.idleRPM;
  float tau = config.flyAlphaTau * config.flywheelInertia;
  if (tau < 0.005f) tau = 0.005f;
  if (tau > 0.8f) tau = 0.8f;
  float a = deltaTime / (tau + deltaTime);
  if (a > 1.0f) a = 1.0f; if (a < 0.0f) a = 0.0f;
  flywheelRPM = flywheelRPM * (1.0f - a) + averagedRPM * a;
  float error = flywheelRPM - averagedRPM;
  if (error > 3000.0f) error = 3000.0f; if (error < -3000.0f) error = -3000.0f;
  // Wyrównanie przy zmianie kierunku wzrostu (nie sztywno, ale po ustaleniu/nawrocie fly=avg)
  // Histereza 5 RPM przeciw migotaniu na szumie Halli przy przejsciu przez zero.
  static float prevError = 0.0f;
  if ((prevError > 5.0f && error < -5.0f) || (prevError < -5.0f && error > 5.0f)) {
    flywheelRPM = averagedRPM;
    lastSlewedCorr = 0.0f;
    prevError = 0.0f;
    return desiredPWM;
  }
  prevError = error;
  // Dociaganie w strefie malej: |error|<20 RPM -> fly szybciej do avg, korekta sama ~0
  if (fabsf(error) < 20.0f) {
    flywheelRPM += (averagedRPM - flywheelRPM) * 0.5f;
  }
  // Prawdziwy silnik: ponizej 10% gazu wyrownaj (nie ciagnij), ale przy spadku RPM zawsze koryguj (ochrona przed zdlawieniem)
  float gasPos = constrain(mapFloat(lastAnalogValue, config.adcMin, config.adcMax, 0.0f, 1.0f), 0.0f, 1.0f);
  bool throttleLow = gasPos < 0.10f;
  if (throttleLow && error <= 0.0f) {
    // gaz puszczony i brak spadku -> wyrownaj jak w silniku na biegu jalowym, zero korekty
    flywheelRPM = averagedRPM;
    lastSlewedCorr = 0.0f;
    return desiredPWM;
  }
  // gdy throttleLow && error>0 (spadek) -> fall-through, flywheel pomaga nawet <10% (nie pozwol zdlawic)
  float corr = error * config.flyKfw;
  if (corr < 0 && !config.flyGainUpEnabled) corr = 0;
  if (corr > 0 && !config.flyGainDownEnabled) corr = 0;
  float gain = (corr < 0) ? config.flywheelGainUp : config.flywheelGainDown;
  corr *= gain;
  float rpmPos = constrain(averagedRPM / config.flywheelMaxRPM, 0.0f, 1.0f);
  uint16_t mult = (corr < 0) ? interpolateMap(config.fwUpMap, rpmPos) : interpolateMap(config.fwDownMap, rpmPos);
  corr *= (float)mult * 0.01f;
  float slewedCorr;
  if (!config.flySlewEnabled || config.flySlewRecover <= 0.0f) slewedCorr = corr;
  else {
    bool deepening = fabsf(corr) >= fabsf(lastSlewedCorr) + 0.001f;
    if (deepening) slewedCorr = corr;
    else {
      float step = (float)((int)config.pwmMax - (int)config.pwmMin) * (float)config.intervalPetli / config.flySlewRecover;
      float diff = corr - lastSlewedCorr;
      if (diff > step) diff = step; if (diff < -step) diff = -step;
      slewedCorr = lastSlewedCorr + diff;
    }
  }
  lastSlewedCorr = slewedCorr;
  float out = desiredPWM + slewedCorr;
  return constrain(out, (float)config.pwmMin, (float)config.pwmMax);
}

void handleHallSensor(uint8_t sensorIndex, unsigned long now) {
  unsigned long lastTime = hallLastTime[sensorIndex];
  if (lastTime == 0) { hallLastTime[sensorIndex] = now; lastHallTime = now; return; }
  unsigned long edgePeriod = now - lastTime;
  if (edgePeriod < hallFilterUs) return;
  hallLastTime[sensorIndex] = now; lastHallTime = now;
  unsigned long prev = hallLastPeriod[sensorIndex];
  hallLastPeriod[sensorIndex] = edgePeriod;
  hallPeriod = (prev > 0) ? (edgePeriod + prev) : (edgePeriod * 2UL);
  newHallPulse = true;
}
void hallISR() {
  unsigned long now = micros();
  uint8_t pins = PIND & HALL_PIN_MASK;
  uint8_t changed = pins ^ lastHallPins;
  lastHallPins = pins;
  if (changed & _BV(PD4)) handleHallSensor(0, now);
  if (changed & _BV(PD5)) handleHallSensor(1, now);
  if (changed & _BV(PD6)) handleHallSensor(2, now);
}
ISR(PCINT2_vect) { hallISR(); }

void updateRPM() {
  if (newHallPulse) {
    noInterrupts(); unsigned long period = hallPeriod; newHallPulse = false; interrupts();
    if (period > 0 && period < 1000000UL && config.paryBiegunow > 0) {
      currentRPM = (60.0f * 1000000.0f) / ((float)period * config.paryBiegunow);
      if (averagedRPM == 0.0f) averagedRPM = currentRPM;
    }
  }
  noInterrupts(); unsigned long safeLastHallTime = lastHallTime; unsigned long safeHallPeriod = hallPeriod; interrupts();
  unsigned long timeSinceHall = micros() - safeLastHallTime;
  if (timeSinceHall > safeHallPeriod && safeHallPeriod > 0 && config.paryBiegunow > 0) {
    float estimatedRPM = (60.0f * 1000000.0f) / ((float)timeSinceHall * config.paryBiegunow);
    if (estimatedRPM < currentRPM) currentRPM = estimatedRPM;
  }
  float rawRPM = currentRPM;
  static float filteredRPM = 0.0f;
  if (filteredRPM == 0.0f) filteredRPM = rawRPM;
  filteredRPM = filteredRPM * (1.0f - config.rpmAlpha) + rawRPM * config.rpmAlpha;
  currentRPM = filteredRPM;
  averagedRPM = currentRPM;
  if (micros() - safeLastHallTime > 1000000UL) { averagedRPM = config.idleRPM; }
  if (averagedRPM < config.idleRPM) { averagedRPM = config.idleRPM; }
}

void updateLog(unsigned long currentTime) {
  if (!logMode || !logOut) return;
  static unsigned long lastLog = 0;
  if (currentTime - lastLog < 10) return;
  lastLog = currentTime;
  logOut->print(currentTime - logStartTime); logOut->print(F(","));
  logOut->print(lastAnalogValueRaw);         logOut->print(F(","));
  logOut->print(lastAnalogValue);            logOut->print(F(","));
  logOut->print((int)targetPWM);             logOut->print(F(","));
  logOut->print(averagedRPM, 1);             logOut->print(F(","));
  logOut->print(flywheelRPM, 0);             logOut->print(F(","));
  logOut->print(lastClutchPercent);          logOut->print(F(","));
  logOut->println(lastCalculatedPwm);
}

void processCommand(char* cmd) {
  if (strcmp(cmd, "help") == 0 || strcmp(cmd, "?") == 0) {
    activeOut->println(F("cal,cc,reset,gc,scc,sth,sfwup/sfwdown,sramp,log on/off"));
    activeOut->println(F("set filter/loop/poles/pwmmin/pwmmax/gasmin/gasmax/clmin/clmax/idle"));
    activeOut->println(F("set clmap/thmap/fwupmap/fwdownmap/rampgasmap <i> <val>"));
    activeOut->println(F("set then/clen/flywheel on/off, fwgainenabledup/down on/off"));
    activeOut->println(F("set flywheelinertia 0.1-10 / flywheelmax 1k-50k / fwgainup/down 0.1-30"));
    activeOut->println(F("set fwdeadband on/off / fwdeadbandrpm 0-5000 / fwslew on/off / fwslew 0-2000"));
    activeOut->println(F("set rpma 0.05-1.0 / alpha 0.005-0.5 / flyk 0.01-0.2"));
    activeOut->println(F("test on/off, set testadc 196-500, fly on/off (alias)"));
    activeOut->println(F("OK"));
  } else if (strcmp(cmd, "reset") == 0) { resetConfig();
  } else if (strcmp(cmd, "ver") == 0) { activeOut->println(F("ready v" VERSION));
  } else if (strcmp(cmd, "cal") == 0) { calibrateThrottle();
  } else if (strcmp(cmd, "cc") == 0) { calibrateClutch();
  } else if (strncmp(cmd, "set poles ", 10) == 0) {
    int v = atoi(cmd + 10);
    if (v >= 1 && v <= 20) { config.paryBiegunow = (uint8_t)v; markConfigDirty(); activeOut->println(F("OK")); } else activeOut->println(F("e:1-20"));
  } else if (strncmp(cmd, "set filter ", 11) == 0) {
    long v = atol(cmd + 11);
    if (v >= 50 && v <= 5000) { config.filtrHalla = (uint16_t)v; noInterrupts(); hallFilterUs = config.filtrHalla; interrupts(); markConfigDirty(); activeOut->println(F("OK")); } else activeOut->println(F("e:50-5k"));
  } else if (strncmp(cmd, "set loop ", 9) == 0) {
    int v = atoi(cmd + 9);
    if (v >= 2 && v <= 100) { config.intervalPetli = (uint8_t)v; markConfigDirty(); activeOut->println(F("OK")); } else activeOut->println(F("e:2-100"));
  } else if (strncmp(cmd, "set pwmmin ", 11) == 0) {
    int v = atoi(cmd + 11);
    if (v >= 0 && v <= 1023 && v < (int)config.pwmMax) { config.pwmMin = (uint16_t)v; markConfigDirty(); activeOut->println(F("OK")); } else activeOut->println(F("e:<px"));
  } else if (strncmp(cmd, "set pwmmax ", 11) == 0) {
    int v = atoi(cmd + 11);
    if (v >= 0 && v <= 1023 && v > (int)config.pwmMin) { config.pwmMax = (uint16_t)v; markConfigDirty(); activeOut->println(F("OK")); } else activeOut->println(F("e:>pm"));
  } else if (strncmp(cmd, "set gasmin ", 11) == 0) {
    int v = atoi(cmd + 11);
    if (v >= 0 && v <= 1023 && (uint16_t)v < config.adcMax) { config.adcMin = (uint16_t)v; markConfigDirty(); activeOut->println(F("OK")); } else activeOut->println(F("e:<ax"));
  } else if (strncmp(cmd, "set gasmax ", 11) == 0) {
    int v = atoi(cmd + 11);
    if (v >= 0 && v <= 1023 && (uint16_t)v > config.adcMin) { config.adcMax = (uint16_t)v; markConfigDirty(); activeOut->println(F("OK")); } else activeOut->println(F("e:>am"));
  } else if (strcmp(cmd, "set clen on")  == 0) { config.clutchEnabled = true;  markConfigDirty(); activeOut->println(F("OK"));
  } else if (strcmp(cmd, "set clen off") == 0) { config.clutchEnabled = false; markConfigDirty(); activeOut->println(F("OK"));
  } else if (strcmp(cmd, "set then on")  == 0) { config.throttleMapEnabled = true;  markConfigDirty(); activeOut->println(F("OK"));
  } else if (strcmp(cmd, "set then off") == 0) { config.throttleMapEnabled = false; markConfigDirty(); activeOut->println(F("OK"));
  } else if (strcmp(cmd, "set flywheel on")  == 0) { config.flywheelEnabled = true;  markConfigDirty(); activeOut->println(F("OK"));
  } else if (strcmp(cmd, "set flywheel off") == 0) { config.flywheelEnabled = false; markConfigDirty(); activeOut->println(F("OK"));
  } else if (strcmp(cmd, "fly on")  == 0) { config.flywheelEnabled = true;  markConfigDirty(); activeOut->println(F("OK"));
  } else if (strcmp(cmd, "fly off") == 0) { config.flywheelEnabled = false; markConfigDirty(); activeOut->println(F("OK"));
  } else if (strcmp(cmd, "set fwgainenabledup on")   == 0) { config.flyGainUpEnabled = true;   markConfigDirty(); activeOut->println(F("OK"));
  } else if (strcmp(cmd, "set fwgainenabledup off")  == 0) { config.flyGainUpEnabled = false;  markConfigDirty(); activeOut->println(F("OK"));
  } else if (strcmp(cmd, "set fwgainenableddown on") == 0) { config.flyGainDownEnabled = true;   markConfigDirty(); activeOut->println(F("OK"));
  } else if (strcmp(cmd, "set fwgainenableddown off") == 0) { config.flyGainDownEnabled = false;  markConfigDirty(); activeOut->println(F("OK"));
  } else if (strcmp(cmd, "set fwdeadband on")  == 0) { config.flyDeadbandEnabled = true;  markConfigDirty(); activeOut->println(F("OK"));
  } else if (strcmp(cmd, "set fwdeadband off") == 0) { config.flyDeadbandEnabled = false; markConfigDirty(); activeOut->println(F("OK"));
  } else if (strncmp(cmd, "set fwdeadbandrpm ", 18) == 0) {
    float v = atof(cmd + 18);
    if (v >= 0.0f && v <= 5000.0f) { config.flyDeadbandRPM = v; markConfigDirty(); activeOut->println(F("OK")); } else activeOut->println(F("e:0-5000"));
  } else if (strcmp(cmd, "set fwslew on") == 0) { config.flySlewEnabled = true; if (config.flySlewRecover <= 0.0f) config.flySlewRecover = 350.0f; markConfigDirty(); activeOut->println(F("OK"));
  } else if (strcmp(cmd, "set fwslew off") == 0) { config.flySlewEnabled = false; markConfigDirty(); activeOut->println(F("OK"));
  } else if (strncmp(cmd, "set fwslew ", 11) == 0) {
    float v = atof(cmd + 11);
    if (v >= 0.0f && v <= 2000.0f) { config.flySlewRecover = v; if (v <= 0.0f) config.flySlewEnabled = false; markConfigDirty(); activeOut->println(F("OK")); } else activeOut->println(F("e:0-2000"));
  } else if (strncmp(cmd, "set flywheelinertia ", 20) == 0) {
    float v = atof(cmd + 20);
    if (v >= 0.1f && v <= 10.0f) { config.flywheelInertia = v; markConfigDirty(); activeOut->println(F("OK")); } else activeOut->println(F("e:0.1-10.0"));
  } else if (strncmp(cmd, "set fwgainup ", 13) == 0) {
    float v = atof(cmd + 13);
    if (v >= 0.1f && v <= 30.0f) { config.flywheelGainUp = v; markConfigDirty(); activeOut->println(F("OK")); } else activeOut->println(F("e:0.1-30.0"));
  } else if (strncmp(cmd, "set fwgaindown ", 15) == 0) {
    float v = atof(cmd + 15);
    if (v >= 0.1f && v <= 30.0f) { config.flywheelGainDown = v; markConfigDirty(); activeOut->println(F("OK")); } else activeOut->println(F("e:0.1-30.0"));
  } else if (strncmp(cmd, "set flywheelmax ", 16) == 0) {
    float v = atof(cmd + 16);
    if (v >= 1000.0f && v <= 50000.0f) { config.flywheelMaxRPM = v; markConfigDirty(); activeOut->println(F("OK")); } else activeOut->println(F("e:1k-50k"));
  } else if (strncmp(cmd, "set clmin ", 10) == 0) {
    int v = atoi(cmd + 10);
    if (v >= 0 && v < (int)config.clutchAdcMax && v < 1023) { config.clutchAdcMin = (uint16_t)v; markConfigDirty(); activeOut->println(F("OK")); } else activeOut->println(F("e:<cx"));
  } else if (strncmp(cmd, "set clmax ", 10) == 0) {
    int v = atoi(cmd + 10);
    if (v > (int)config.clutchAdcMin && v <= 1023) { config.clutchAdcMax = (uint16_t)v; markConfigDirty(); activeOut->println(F("OK")); } else activeOut->println(F("e:>cm"));
  } else if (strncmp(cmd, "set clmap ", 10) == 0) {
    int idx = atoi(cmd + 10); char* valPtr = strchr(cmd + 11, ' ');
    if (valPtr) { int val = atoi(valPtr + 1);
      if (idx >= 0 && idx < MAP_SIZE && val >= 0 && val <= 1023) { config.clutchMap[idx] = (uint16_t)val; markConfigDirty(); activeOut->println(F("OK")); } else activeOut->println(F("e:idx 0-24, val 0-1023"));
    } else activeOut->println(F("e:clmap"));
  } else if (strncmp(cmd, "set thmap ", 10) == 0) {
    int idx = atoi(cmd + 10); char* valPtr = strchr(cmd + 11, ' ');
    if (valPtr) { int val = atoi(valPtr + 1);
      if (idx >= 0 && idx < MAP_SIZE && val >= 0 && val <= 1023) { config.throttleMap[idx] = (uint16_t)val; markConfigDirty(); activeOut->println(F("OK")); } else activeOut->println(F("e:idx 0-24, val 0-1023"));
    } else activeOut->println(F("e:thmap"));
  } else if (strncmp(cmd, "set idle ", 9) == 0) {
    float v = atof(cmd + 9);
    if (v >= 50.0f && v <= 1000.0f) { config.idleRPM = v; saveConfigNow(); activeOut->println(F("OK")); } else activeOut->println(F("e:50-1000"));
  } else if (strncmp(cmd, "set rampgasmap ", 15) == 0) {
    char* idxStr = cmd + 15; char* valPtr = strchr(idxStr, ' ');
    if (valPtr) { int idx = atoi(idxStr); long v  = atol(valPtr + 1);
      if (idx >= 0 && idx < MAP_SIZE && v >= 0 && v <= 2000) { config.rampMap[idx] = (uint16_t)v; markConfigDirty(); activeOut->println(F("OK")); } else activeOut->println(F("e:0-24,0-2000"));
    } else activeOut->println(F("e:rampgasmap"));
  } else if (strcmp(cmd, "sramp") == 0) {
    activeOut->println(F("srampstart"));
    for (int i = 0; i < MAP_SIZE; i++) { activeOut->print(i); activeOut->print(F(":")); activeOut->println(config.rampMap[i]); }
    activeOut->println(F("srampend"));
  } else if (strncmp(cmd, "set rpma ", 9) == 0) {
    float v = atof(cmd + 9);
    if (v >= 0.05f && v <= 1.0f) { config.rpmAlpha = v; markConfigDirty(); activeOut->println(F("OK")); } else activeOut->println(F("e:0.05-1.0"));
  } else if (strncmp(cmd, "set alpha ", 10) == 0) {
    float v = atof(cmd + 10);
    if (v >= 0.005f && v <= 0.5f) { config.flyAlphaTau = v; markConfigDirty(); activeOut->println(F("OK")); } else activeOut->println(F("e:0.005-0.5"));
  } else if (strncmp(cmd, "set flyk ", 9) == 0) {
    float v = atof(cmd + 9);
    if (v >= 0.01f && v <= 0.2f) { config.flyKfw = v; markConfigDirty(); activeOut->println(F("OK")); } else activeOut->println(F("e:0.01-0.2"));
  } else if (strcmp(cmd, "gc") == 0) {
    activeOut->println(F("cs"));
    activeOut->print(F("poles,"));        activeOut->println(config.paryBiegunow);
    activeOut->print(F("filter,"));       activeOut->println(config.filtrHalla);
    activeOut->print(F("loop,"));         activeOut->println(config.intervalPetli);
    activeOut->print(F("rpma,"));         activeOut->println(config.rpmAlpha);
    activeOut->print(F("alpha,"));        activeOut->println(config.flyAlphaTau);
    activeOut->print(F("gasmin,"));       activeOut->println(config.adcMin);
    activeOut->print(F("gasmax,"));       activeOut->println(config.adcMax);
    activeOut->print(F("pwmmin,"));       activeOut->println(config.pwmMin);
    activeOut->print(F("pwmmax,"));       activeOut->println(config.pwmMax);
    activeOut->print(F("clmin,"));        activeOut->println(config.clutchAdcMin);
    activeOut->print(F("clmax,"));        activeOut->println(config.clutchAdcMax);
    activeOut->print(F("clen,"));         activeOut->println(config.clutchEnabled ? 1 : 0);
    activeOut->print(F("then,"));         activeOut->println(config.throttleMapEnabled ? 1 : 0);
    activeOut->print(F("flywheel,"));     activeOut->println(config.flywheelEnabled ? 1 : 0);
    activeOut->print(F("fwgainupenabled,")); activeOut->println(config.flyGainUpEnabled ? 1 : 0);
    activeOut->print(F("fwgaindownenabled,")); activeOut->println(config.flyGainDownEnabled ? 1 : 0);
    activeOut->print(F("flywheelinertia,")); activeOut->println(config.flywheelInertia);
    activeOut->print(F("flywheelmax,"));    activeOut->println(config.flywheelMaxRPM);
    activeOut->print(F("fwgainup,"));    activeOut->println(config.flywheelGainUp);
    activeOut->print(F("fwgaindown,"));  activeOut->println(config.flywheelGainDown);
    activeOut->print(F("fwdeadband,"));  activeOut->println(config.flyDeadbandEnabled ? 1 : 0);
    activeOut->print(F("fwdeadbandrpm,")); activeOut->println(config.flyDeadbandRPM);
    activeOut->print(F("fwslew,"));        activeOut->println(config.flySlewRecover);
    activeOut->print(F("fwslewenabled,")); activeOut->println(config.flySlewEnabled ? 1 : 0);
    activeOut->print(F("flyk,"));          activeOut->println(config.flyKfw);
    activeOut->print(F("flyrpm,"));        activeOut->println(flywheelRPM, 1);
    activeOut->print(F("clutchlock,"));    activeOut->println(clutchUnlocked ? 1 : 0);
    activeOut->print(F("idle,"));         activeOut->println(config.idleRPM);
    activeOut->println(F("cfe")); activeOut->println(F("OK"));
  } else if (strcmp(cmd, "scc") == 0) {
    activeOut->println(F("clstart"));
    for (int i = 0; i < MAP_SIZE; i++) { activeOut->print(i); activeOut->print(F(":")); activeOut->println(config.clutchMap[i]); }
    activeOut->println(F("clend"));
  } else if (strcmp(cmd, "sth") == 0) {
    activeOut->println(F("thstart"));
    for (int i = 0; i < MAP_SIZE; i++) { activeOut->print(i); activeOut->print(F(":")); activeOut->println(config.throttleMap[i]); }
    activeOut->println(F("thend"));
  } else if (strcmp(cmd, "sfwup") == 0) {
    activeOut->println(F("fwupstart"));
    for (int i = 0; i < MAP_SIZE; i++) { activeOut->print(i); activeOut->print(F(":")); activeOut->println(config.fwUpMap[i]); }
    activeOut->println(F("fwupend"));
  } else if (strcmp(cmd, "sfwdown") == 0) {
    activeOut->println(F("fwdownstart"));
    for (int i = 0; i < MAP_SIZE; i++) { activeOut->print(i); activeOut->print(F(":")); activeOut->println(config.fwDownMap[i]); }
    activeOut->println(F("fwdownend"));
  } else if (strncmp(cmd, "set fwupmap ", 12) == 0) {
    int idx = atoi(cmd + 12); char* valPtr = strchr(cmd + 13, ' ');
    if (valPtr) { int val = atoi(valPtr + 1);
      if (idx >= 0 && idx < MAP_SIZE && val >= 0 && val <= 1000) { config.fwUpMap[idx] = (uint16_t)val; markConfigDirty(); activeOut->println(F("OK")); } else activeOut->println(F("e:idx 0-24, val 0-1000"));
    } else activeOut->println(F("e:fwupmap"));
  } else if (strncmp(cmd, "set fwdownmap ", 14) == 0) {
    int idx = atoi(cmd + 14); char* valPtr = strchr(cmd + 15, ' ');
    if (valPtr) { int val = atoi(valPtr + 1);
      if (idx >= 0 && idx < MAP_SIZE && val >= 0 && val <= 1000) { config.fwDownMap[idx] = (uint16_t)val; markConfigDirty(); activeOut->println(F("OK")); } else activeOut->println(F("e:idx 0-24, val 0-1000"));
    } else activeOut->println(F("e:fwdownmap"));
  } else if (strcmp(cmd, "log on") == 0) { logMode = true; logStartTime = millis(); logOut = activeOut; activeOut->println(F("OK"));
  } else if (strcmp(cmd, "log off") == 0) { logMode = false; logOut = nullptr; activeOut->println(F("OK"));
  } else if (strcmp(cmd, "test on") == 0) {
    testMode = true; logMode = true; logOut = activeOut;
    testPhase = 1; testPhaseStart = 0; testCycleCount = 0;
    logStartTime = millis(); activeOut->println(F("OK"));
  } else if (strcmp(cmd, "test off") == 0) {
    testMode = false; logMode = false; logOut = nullptr;
    testPhase = 1; testPhaseStart = 0; testCycleCount = 0; activeOut->println(F("OK"));
  } else if (strncmp(cmd, "set testadc ", 12) == 0) {
    int v = atoi(cmd + 12);
    if (v >= 196 && v <= 500) { testAdc = (uint16_t)v; activeOut->println(F("OK")); } else activeOut->println(F("e:196-500"));
  } else if (strlen(cmd) > 0) { activeOut->print(F("e:?")); activeOut->println(cmd); }
}

void delayWdt(unsigned long ms) {
  unsigned long end = millis() + ms;
  while ((long)(end - millis()) > 0) { delay(10); wdt_reset(); }
}
void calibrateThrottle() {
  if (averagedRPM > config.idleRPM + 100.0f) { activeOut->println(F("e:stop")); return; }
  OCR1A = 0;
  activeOut->println(F("=== Kalibracja gazu ==="));
  activeOut->println(F("Krok 1/2: PUSC gaz na 3s...")); delayWdt(3000);
  activeOut->println(F("Probkowanie..."));
  uint32_t sumMin = 0; uint16_t samplesMin = 0; uint32_t t = millis();
  while (millis() - t < 5000) { sumMin += analogRead(ANALOG_INPUT); samplesMin++; delay(5); wdt_reset(); }
  uint16_t adcMin = (samplesMin > 0) ? (sumMin / samplesMin) : 0;
  activeOut->print(F("ADC min=")); activeOut->println(adcMin);
  activeOut->println(F("Krok 2/2: WCISNIJ gaz max na 3s...")); delayWdt(3000);
  activeOut->println(F("Probkowanie..."));
  uint32_t sumMax = 0; uint16_t samplesMax = 0; t = millis();
  while (millis() - t < 5000) { sumMax += analogRead(ANALOG_INPUT); samplesMax++; delay(5); wdt_reset(); }
  uint16_t adcMax = (samplesMax > 0) ? (sumMax / samplesMax) : 1023;
  activeOut->print(F("ADC max=")); activeOut->println(adcMax);
  int range = adcMax - adcMin;
  if (adcMin >= adcMax || range < 300) { activeOut->println(F("e:<300")); return; }
  activeOut->println(F("Krok 3/3: PUSC gaz..."));
  int releaseThreshold = adcMin + range / 10;
  unsigned long waitStart = millis();
  while (analogRead(ANALOG_INPUT) > releaseThreshold) {
    if (millis() - waitStart >= 15000) { activeOut->println(F("e:timeout")); return; }
    delay(50); wdt_reset();
  }
  activeOut->println(F("Gaz puszczony."));
  config.adcMin = adcMin; config.adcMax = adcMax;
  saveConfigNow(); activeOut->println(F("OK"));
}
void calibrateClutch() {
  if (averagedRPM > config.idleRPM + 100.0f) { activeOut->println(F("e:stop")); return; }
  OCR1A = 0;
  activeOut->println(F("=== Kalibracja sprzegla ==="));
  activeOut->println(F("Krok 1/2: PUSC sprzeglo na 3s...")); delayWdt(3000);
  activeOut->println(F("Probkowanie..."));
  uint32_t sumMin = 0; uint16_t samplesMin = 0; uint32_t t = millis();
  while (millis() - t < 5000) { sumMin += analogRead(CLUTCH_INPUT); samplesMin++; delay(5); wdt_reset(); }
  uint16_t clMin = (samplesMin > 0) ? (sumMin / samplesMin) : 0;
  activeOut->print(F("ADC min=")); activeOut->println(clMin);
  activeOut->println(F("Krok 2/2: WCISNIJ sprzeglo max na 3s...")); delayWdt(3000);
  activeOut->println(F("Probkowanie..."));
  uint32_t sumMax = 0; uint16_t samplesMax = 0; t = millis();
  while (millis() - t < 5000) { sumMax += analogRead(CLUTCH_INPUT); samplesMax++; delay(5); wdt_reset(); }
  uint16_t clMax = (samplesMax > 0) ? (sumMax / samplesMax) : 1023;
  activeOut->print(F("ADC max=")); activeOut->println(clMax);
  int range = clMax - clMin;
  if (clMin >= clMax || range < 300) { activeOut->println(F("e:<300")); return; }
  activeOut->println(F("Krok 3/3: PUSC sprzeglo..."));
  int releaseThreshold = clMin + range / 10;
  unsigned long waitStart2 = millis();
  while (analogRead(CLUTCH_INPUT) > releaseThreshold) {
    if (millis() - waitStart2 >= 15000) { activeOut->println(F("e:timeout")); return; }
    delay(50); wdt_reset();
  }
  activeOut->println(F("Sprzeglo puszczone."));
  config.clutchAdcMin = clMin; config.clutchAdcMax = clMax;
  saveConfigNow(); activeOut->println(F("OK"));
}

void handleSerial() {
  if (!Serial.available()) return;
  static char cmd[32]; static int pos = 0;
  while (Serial.available()) {
    char c = Serial.read();
    if (c == '\n' || c == '\r') {
      if (pos == 0) continue;
      cmd[pos] = '\0'; pos = 0;
      Stream* prevOut = activeOut;
      activeOut = &Serial;
      activeOut->print(F("> ")); activeOut->println(cmd);
      processCommand(cmd);
      activeOut = prevOut;
      memset(cmd, 0, sizeof(cmd)); return;
    } else { if (pos < 31) cmd[pos++] = c; else { pos = 0; memset(cmd, 0, sizeof(cmd)); } }
  }
}

void setup() {
  Serial.begin(115200);
  activeOut = &Serial;
  loadConfig();
  clutchUnlocked = false; clutchUnlockCount = 0;
  pinMode(PWM_PIN, OUTPUT);
  pinMode(ANALOG_INPUT, INPUT);
  pinMode(CLUTCH_INPUT, INPUT);
  pinMode(HALL_SENSOR, INPUT_PULLUP);
  pinMode(HALL_SENSOR_2, INPUT_PULLUP);
  pinMode(HALL_SENSOR_3, INPUT_PULLUP);
  TCCR1A = _BV(COM1A1) | _BV(WGM11) | _BV(WGM10);
  TCCR1B = _BV(WGM12) | _BV(CS10);
  OCR1A = 0;
  lastHallPins = PIND & HALL_PIN_MASK;
  PCICR  |= (1 << PCIE2);
  PCMSK2 |= (1 << PCINT20) | (1 << PCINT21) | (1 << PCINT22);
  PCIFR  |= (1 << PCIF2);
  activeOut->print(F("ready v" VERSION));
  if (config.throttleMapEnabled) activeOut->print(F(" THMAP"));
  if (config.flywheelEnabled) activeOut->print(F(" FLYWHEEL"));
  activeOut->println();
  lastLoopTime = millis();
  wdt_enable(WDTO_1S);
}

void loop() {
  wdt_reset();
  unsigned long currentTime = millis();
  if (currentTime - lastLoopTime >= config.intervalPetli) {
    float deltaTime = (currentTime - lastLoopTime) / 1000.0f;
    if (deltaTime < 0.001f) deltaTime = 0.001f;
    lastLoopTime = currentTime;
    updateTestMode(currentTime);
    readThrottle();
    updateRPM();
    float pwm = applyFlywheel(targetPWM, deltaTime);
    lastCalculatedPwm = (int)pwm;
    updateLog(currentTime);
  }
  updateClutch();
  flushConfig();
  handleSerial();
}
