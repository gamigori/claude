// 번개를 캔버스에 그림 (위젯과 칩 창이 같이 씀)
// 빛나는 선이 아니라, 각진 단색 조각이 끝으로 갈수록 뾰족해지는 애니 스타일 전기
window.createLightning = function (canvas) {
  const ctx = canvas.getContext('2d');
  const bolts = [];
  // 빨강과 초록 반반 (카프리 색)
  const COLORS = ['#ff2a4a', '#2bff7a'];
  const EDGE = 'rgba(150, 60, 255, .85)'; // 살짝 어긋난 보라 테두리

  function fit() {
    const dpr = window.devicePixelRatio || 1;
    const w = canvas.clientWidth, h = canvas.clientHeight;
    if (canvas.width !== Math.round(w * dpr) || canvas.height !== Math.round(h * dpr)) {
      canvas.width = Math.round(w * dpr);
      canvas.height = Math.round(h * dpr);
    }
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    return [w, h];
  }

  // 두 점 사이를 몇 번만 쪼개서 크게 꺾이는 지그재그를 만듦 (많이 쪼개면 둥글어 보임)
  function jag(x1, y1, x2, y2) {
    const len = Math.hypot(x2 - x1, y2 - y1);
    let pts = [{ x: x1, y: y1 }, { x: x2, y: y2 }];
    for (let d = len * 0.45; d > Math.max(6, len * 0.08); d /= 2) {
      const out = [pts[0]];
      for (let i = 1; i < pts.length; i++) {
        const a = pts[i - 1], b = pts[i];
        const l = Math.hypot(b.x - a.x, b.y - a.y) || 1;
        const off = (Math.random() - 0.5) * d;
        out.push({ x: (a.x + b.x) / 2 - ((b.y - a.y) / l) * off, y: (a.y + b.y) / 2 + ((b.x - a.x) / l) * off }, b);
      }
      pts = out;
    }
    return pts;
  }

  // 지그재그 선을 따라 굵기가 들쭉날쭉하다 끝이 뾰족해지는 다각형을 만듦
  function shard(pts, width) {
    const n = pts.length;
    const left = [], right = [];
    for (let i = 0; i < n; i++) {
      const a = pts[Math.max(0, i - 1)], b = pts[Math.min(n - 1, i + 1)];
      const l = Math.hypot(b.x - a.x, b.y - a.y) || 1;
      const nx = -(b.y - a.y) / l, ny = (b.x - a.x) / l;
      const taper = Math.pow(1 - i / (n - 1), 0.6);
      const w = width * 3 * taper * (0.55 + Math.random() * 0.9);
      // 한쪽만 튀어나오게 해서 깨진 조각처럼
      const kink = (Math.random() - 0.5) * w * 0.8;
      left.push({ x: pts[i].x + nx * (w / 2 + kink), y: pts[i].y + ny * (w / 2 + kink) });
      right.push({ x: pts[i].x - nx * (w / 2 - kink), y: pts[i].y - ny * (w / 2 - kink) });
    }
    return left.concat(right.reverse());
  }

  function spawn(x1, y1, x2, y2, { width = 2, life = 260, branches = 2, color } = {}) {
    const len = Math.hypot(x2 - x1, y2 - y1);
    const pts = jag(x1, y1, x2, y2);
    const born = performance.now();
    const col = color || COLORS[Math.floor(Math.random() * COLORS.length)];
    bolts.push({ poly: shard(pts, width), color: col, born, life });
    for (let i = 0; i < branches && pts.length > 2; i++) {
      const p = pts[1 + Math.floor(Math.random() * (pts.length - 2))];
      const ang = Math.atan2(y2 - y1, x2 - x1) + (Math.random() - 0.5) * 1.6;
      const l = len * (0.2 + Math.random() * 0.3);
      const bp = jag(p.x, p.y, p.x + Math.cos(ang) * l, p.y + Math.sin(ang) * l);
      bolts.push({ poly: shard(bp, width * 0.6), color: col, born, life: life * 0.8 });
    }
  }

  function fillPoly(poly, dx, dy) {
    ctx.beginPath();
    poly.forEach((p, j) => (j ? ctx.lineTo(p.x + dx, p.y + dy) : ctx.moveTo(p.x + dx, p.y + dy)));
    ctx.closePath();
    ctx.fill();
  }

  function draw() {
    const [w, h] = fit();
    ctx.clearRect(0, 0, w, h);
    const now = performance.now();
    ctx.lineJoin = 'miter';
    for (let i = bolts.length - 1; i >= 0; i--) {
      const b = bolts[i];
      const age = (now - b.born) / b.life;
      if (age >= 1) { bolts.splice(i, 1); continue; }
      // 서서히 흐려지지 않고, 뚝뚝 끊기며 깜빡이다 사라짐
      if (Math.random() < 0.2 || (age > 0.65 && Math.random() < 0.5)) continue;
      ctx.fillStyle = EDGE;
      fillPoly(b.poly, 2, 1.5);
      ctx.fillStyle = b.color;
      fillPoly(b.poly, 0, 0);
    }
  }

  return { spawn, draw, size: () => [canvas.clientWidth, canvas.clientHeight] };
};
