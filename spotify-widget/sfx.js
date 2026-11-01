// 효과음: 소리 파일 없이 Web Audio 로 직접 만들어 냄 (위젯과 칩 창이 같이 씀)
window.createSfx = function () {
  let ctx = null;
  let enabled = true;
  let drone = null;
  const files = {}; // 효과음 이름 → 폴더에 넣은 소리 파일

  const ac = () => (ctx ||= new AudioContext());

  function out(volume) {
    const g = ac().createGain();
    g.gain.value = volume;
    g.connect(ac().destination);
    return g;
  }

  function noise(seconds) {
    const c = ac();
    const buf = c.createBuffer(1, Math.ceil(c.sampleRate * seconds), c.sampleRate);
    const d = buf.getChannelData(0);
    for (let i = 0; i < d.length; i++) d[i] = Math.random() * 2 - 1;
    const src = c.createBufferSource();
    src.buffer = buf;
    return src;
  }

  // 빠르게 커졌다가 서서히 사라지는 볼륨
  function envelope(param, t, attack, peak, decay) {
    param.setValueAtTime(0.0001, t);
    param.exponentialRampToValueAtTime(peak, t + attack);
    param.exponentialRampToValueAtTime(0.0001, t + attack + decay);
  }

  // f0 에서 f1 으로 음이 미끄러지는 소리
  function tone(type, f0, f1, start, dur, vol, dest) {
    const c = ac();
    const o = c.createOscillator();
    const g = c.createGain();
    o.type = type;
    o.frequency.setValueAtTime(f0, start);
    o.frequency.exponentialRampToValueAtTime(f1, start + dur);
    envelope(g.gain, start, 0.005, vol, dur);
    o.connect(g).connect(dest);
    o.start(start);
    o.stop(start + dur + 0.05);
  }

  function filteredNoise(type, freq, start, dur, vol, dest, freqTo) {
    const c = ac();
    const n = noise(dur + 0.05);
    const f = c.createBiquadFilter();
    const g = c.createGain();
    f.type = type;
    f.frequency.setValueAtTime(freq, start);
    if (freqTo) f.frequency.exponentialRampToValueAtTime(freqTo, start + dur);
    f.Q.value = 1.2;
    envelope(g.gain, start, 0.01, vol, dur);
    n.connect(f).connect(g).connect(dest);
    n.start(start);
    n.stop(start + dur + 0.05);
  }

  const sounds = {
    // 칩이 바닥에 떨어질 때 금속 '틱'
    land() {
      const t = ac().currentTime;
      const o = out(0.35);
      for (const [f, d] of [[1850, 0.22], [2780, 0.16], [4150, 0.1]]) tone('sine', f, f * 0.98, t, d, 0.5, o);
      filteredNoise('highpass', 5000, t, 0.03, 0.4, o);
    },
    // 칩이 홈으로 미끄러져 들어가는 '치이익' + 끝에 '철컥'
    insert() {
      const t = ac().currentTime;
      const o = out(0.4);
      filteredNoise('bandpass', 700, t, 0.5, 0.6, o, 3200);
      tone('square', 900, 300, t + 0.55, 0.05, 0.25, o);
      tone('sine', 120, 50, t + 0.56, 0.18, 0.9, o);
    },
    // 끝까지 밀어 넣었을 때 '딸깍' + 묵직한 '퉁'
    plugIn() {
      const t = ac().currentTime;
      const o = out(0.45);
      filteredNoise('highpass', 3000, t, 0.025, 0.7, o);
      tone('square', 1400, 900, t, 0.03, 0.35, o);
      tone('square', 1800, 1200, t + 0.045, 0.025, 0.25, o);
      tone('sine', 140, 55, t + 0.01, 0.2, 0.9, o);
    },
    // 뽑아낼 때 '슥-틱'
    plugOut() {
      const t = ac().currentTime;
      const o = out(0.4);
      filteredNoise('bandpass', 2500, t, 0.12, 0.5, o, 900);
      tone('square', 900, 1500, t + 0.1, 0.03, 0.3, o);
    },
    // 번개 '지지직'
    zap(volume = 0.4, length = 0.4) {
      const c = ac();
      const t = c.currentTime;
      const o = out(volume);
      const n = noise(length);
      const f = c.createBiquadFilter();
      const g = c.createGain();
      f.type = 'bandpass';
      f.frequency.value = 2600;
      f.Q.value = 0.8;
      // 볼륨을 마구 끊어서 전기가 튀는 느낌
      g.gain.setValueAtTime(0, t);
      for (let s = 0; s < length; s += 0.012) g.gain.setValueAtTime(Math.random() < 0.55 ? Math.random() : 0, t + s);
      g.gain.setValueAtTime(0, t + length);
      n.connect(f).connect(g).connect(o);
      n.start(t);
      n.stop(t + length + 0.02);
      tone('sawtooth', 240, 45, t, length * 0.8, 0.3, o);
    },
    // 카프리 잔상: 높낮이가 튀는 디지털 잡음
    capri() {
      const t = ac().currentTime;
      const o = out(0.22);
      for (let i = 0; i < 9; i++) {
        const f = 300 + Math.random() * 1600;
        tone('square', f, f * (0.5 + Math.random()), t + i * 0.05 + Math.random() * 0.02, 0.04, 0.4, o);
      }
      tone('sine', 520, 90, t + 0.5, 0.6, 0.35, o);
    },
    // 척추 마디가 하나씩 켜질 때 '틱' (위로 갈수록 높아짐)
    spineTick(i) {
      const t = ac().currentTime;
      const f = 500 + i * 140;
      tone('triangle', f, f * 1.02, t, 0.06, 0.35, out(0.3));
    },
    // 척추가 켜지는 동안: 높은 유리 같은 음이 떨리며 치솟고, 거꾸로 감은 듯 바람 소리가 차오름
    sandyCharge(seconds = 0.65) {
      const c = ac();
      const t = c.currentTime;
      const o = out(0.35);
      // 빠르게 떨리게 하는 트레몰로
      const trem = c.createGain();
      const lfo = c.createOscillator();
      const lfoGain = c.createGain();
      lfo.frequency.setValueAtTime(14, t);
      lfo.frequency.linearRampToValueAtTime(34, t + seconds);
      lfoGain.gain.value = 0.5;
      trem.gain.value = 0.5;
      lfo.connect(lfoGain).connect(trem.gain);
      trem.connect(o);
      lfo.start(t);
      lfo.stop(t + seconds + 0.1);
      for (const [mul, vol] of [[1, 0.5], [1.5, 0.35], [2, 0.3], [3.01, 0.18]]) {
        const osc = c.createOscillator();
        const g = c.createGain();
        osc.type = 'sine';
        osc.frequency.setValueAtTime(440 * mul, t);
        osc.frequency.exponentialRampToValueAtTime(1320 * mul, t + seconds);
        g.gain.setValueAtTime(0.0001, t);
        g.gain.exponentialRampToValueAtTime(vol, t + seconds * 0.95);
        g.gain.exponentialRampToValueAtTime(0.0001, t + seconds + 0.05);
        osc.connect(g).connect(trem);
        osc.start(t);
        osc.stop(t + seconds + 0.1);
      }
      // 리버스 심벌처럼 점점 커지다 뚝 끊기는 바람
      const n = noise(seconds);
      const f = c.createBiquadFilter();
      const g = c.createGain();
      f.type = 'highpass';
      f.frequency.setValueAtTime(800, t);
      f.frequency.exponentialRampToValueAtTime(6000, t + seconds);
      g.gain.setValueAtTime(0.0001, t);
      g.gain.exponentialRampToValueAtTime(0.5, t + seconds * 0.98);
      g.gain.setValueAtTime(0, t + seconds);
      n.connect(f).connect(g).connect(o);
      n.start(t);
      n.stop(t + seconds + 0.02);
    },
    // 발동: 메아리치는 '팅' + 시간이 늘어지듯 떨어지는 음 + 깊은 '쿵'
    sandyOn() {
      const c = ac();
      const t = c.currentTime;
      const o = out(0.6);
      // 메아리
      const delay = c.createDelay(1);
      const fb = c.createGain();
      delay.delayTime.value = 0.17;
      fb.gain.value = 0.45;
      delay.connect(fb).connect(delay);
      delay.connect(o);
      const ting = c.createGain();
      ting.connect(o);
      ting.connect(delay);
      tone('triangle', 2637, 2637, t, 1.1, 0.35, ting);
      tone('sine', 3951, 3951, t, 0.8, 0.2, ting);
      tone('sine', 1319, 1310, t, 1.2, 0.25, ting);
      // 늘어지는 음: 높은 톱니파가 아래로 떨어지며 점점 먹먹해짐
      const lp = c.createBiquadFilter();
      lp.type = 'lowpass';
      lp.frequency.setValueAtTime(5000, t);
      lp.frequency.exponentialRampToValueAtTime(250, t + 1);
      lp.connect(o);
      tone('sawtooth', 1760, 110, t, 1, 0.22, lp);
      tone('sawtooth', 1766, 109, t, 1, 0.18, lp);
      // 깊은 '쿵'
      tone('sine', 95, 26, t, 1.1, 1, o);
      filteredNoise('lowpass', 1500, t, 0.5, 0.4, o, 120);
    },
    // 끝날 때 시간이 확 돌아오는 '휙'
    sandyOff() {
      const t = ac().currentTime;
      const o = out(0.45);
      tone('sine', 40, 260, t, 0.35, 0.8, o);
      filteredNoise('bandpass', 300, t, 0.35, 0.6, o, 4000);
    },
    // 브레인댄스 들어갈 때/나올 때 신호음, 끌 때 '틱'
    bdIn() {
      const t = ac().currentTime;
      const o = out(0.25);
      tone('sine', 880, 880, t, 0.08, 0.6, o);
      tone('sine', 1320, 1320, t + 0.09, 0.12, 0.6, o);
    },
    bdOut() {
      const t = ac().currentTime;
      const o = out(0.25);
      tone('sine', 1320, 1320, t, 0.08, 0.6, o);
      tone('sine', 660, 660, t + 0.09, 0.14, 0.6, o);
    },
    bdTick() {
      const t = ac().currentTime;
      tone('square', 2200, 1800, t, 0.015, 0.25, out(0.12));
    },
  };

  return {
    // 폴더에 이 이름의 소리 파일이 있으면 만든 소리 대신 그걸 틀어줌 (없으면 조용히 무시)
    useFile(name, urls) {
      for (const url of urls) {
        const a = new Audio(url);
        a.preload = 'auto';
        a.addEventListener('canplaythrough', () => { files[name] ||= a; }, { once: true });
        a.addEventListener('error', () => {}, { once: true });
        a.load();
      }
    },
    hasFile(name) {
      return !!files[name];
    },
    fileSeconds(name) {
      return files[name]?.duration || 0;
    },
    play(name, ...args) {
      if (!enabled) return;
      if (files[name]) {
        const a = files[name].cloneNode();
        a.play().catch(() => {});
        return;
      }
      if (!sounds[name]) return;
      try {
        if (ac().state === 'suspended') ac().resume();
        sounds[name](...args);
      } catch (e) {
        console.error('효과음 실패:', e.message);
      }
    },
    // 산데비스탄 동안 깔리는 낮은 '우웅' 소리
    startDrone() {
      if (!enabled || drone) return;
      try {
        const c = ac();
        const g = c.createGain();
        const f = c.createBiquadFilter();
        f.type = 'lowpass';
        f.frequency.value = 320;
        g.gain.setValueAtTime(0.0001, c.currentTime);
        g.gain.exponentialRampToValueAtTime(0.09, c.currentTime + 0.6);
        f.connect(g).connect(c.destination);
        const oscs = [55, 55.7, 110.4].map((hz) => {
          const o = c.createOscillator();
          o.type = 'sawtooth';
          o.frequency.value = hz;
          o.connect(f);
          o.start();
          return o;
        });
        // 천천히 출렁이게
        const lfo = c.createOscillator();
        const lfoGain = c.createGain();
        lfo.frequency.value = 0.8;
        lfoGain.gain.value = 120;
        lfo.connect(lfoGain).connect(f.frequency);
        lfo.start();
        // 느려진 시간 속 '쿵-쿵' 심장 소리
        const beat = () => {
          const t = c.currentTime;
          const o = out(0.5);
          tone('sine', 62, 38, t, 0.16, 1, o);
          tone('sine', 58, 36, t + 0.22, 0.2, 0.8, o);
        };
        beat();
        drone = { g, nodes: [...oscs, lfo], heart: setInterval(beat, 1300) };
      } catch (e) {
        console.error('효과음 실패:', e.message);
      }
    },
    stopDrone() {
      if (!drone) return;
      const t = ac().currentTime;
      drone.g.gain.cancelScheduledValues(t);
      drone.g.gain.setValueAtTime(drone.g.gain.value, t);
      drone.g.gain.exponentialRampToValueAtTime(0.0001, t + 0.4);
      for (const n of drone.nodes) n.stop(t + 0.45);
      clearInterval(drone.heart);
      drone = null;
    },
    set enabled(v) {
      enabled = v;
      if (!v) this.stopDrone();
    },
    get enabled() {
      return enabled;
    },
  };
};
