const { app, BrowserWindow, ipcMain, screen, shell, Menu, nativeImage } = require('electron');
const path = require('path');
const fs = require('fs');
const http = require('http');
const crypto = require('crypto');

// Spotify 대시보드의 Redirect URI 에 똑같이 등록해야 함
const REDIRECT_PORT = 8888;
const REDIRECT_URI = `http://127.0.0.1:${REDIRECT_PORT}/callback`;
const SCOPES = [
  'user-read-currently-playing',
  'user-read-playback-state',
  'user-modify-playback-state', // 재생/일시정지/이전/다음
  'user-library-read', // 좋아요 여부 확인
  'user-library-modify', // 좋아요 누르기/취소
];

const POLL_MS = 1500;
const WIDGET_SIZE = 300;
const POPUP_SIZE = 240;
const POPUP_MARGIN = 20;

const CHIP_W = 230; // 칩이 옆으로 누워 떨어지니 가로로 긴 창
const CHIP_H = 120;
// 칩 창 안에서 누운 칩의 위치와 크기 (chip.html 의 .chip 과 같게)
const CHIP_BOX_X = 29;
const CHIP_BOX_Y = 26;
const CHIP_LEN = 172;
const CHIP_THICK = 46;
const CHIP_DEPTH = 112; // 끝까지 꽂으면 들어가는 길이 (나머지 60px 은 위젯 옆으로 튀어나와 보임)
const CHIP_DOCK_W = 80; // 꽂혀 있을 때 칩 창 너비 (튀어나온 부분만 덮게)
const SLOT_SNAP = 14; // 홈 높이와 이만큼 가까우면 홈에 착 붙음
// 노치 모드: 노치 아래로 펼쳐지는 카드 크기 (widget.html 의 .notch 스타일과 같게)
const NOTCH_DEFAULT_W = 190; // 노치 너비 추정값 (config.json 의 notchWidth 로 바꿀 수 있음)
const NOTCH_PAD = 30; // 창 양옆 여백 (그림자, 칩이 튀어나올 자리)
const NOTCH_PANEL_W = 320;
const NOTCH_CARD_H = 300;
const CARD_INSET = 8; // 위젯 창 가장자리에서 카드까지 여백 (widget.html 의 body padding)
// 앨범명이나 곡명에 이 말이 들어가면 칩이 떨어짐 (config.json 의 chipKeywords 로 바꿀 수 있음)
const DEFAULT_CHIP_KEYWORDS = ['edgerunners 2', 'edgerunners ii', 'edgerunners season 2'];
// 칩 곡이 아니면서 이 말이 들어가면 산데비스탄을 켤 수 있음 (config.json 의 sandyKeywords)
const DEFAULT_SANDY_KEYWORDS = ['edgerunners'];

let widgetWin = null;
let popupWin = null;
let chipWin = null;
let chipState = 'none'; // none | falling | dropped | inserted
let notchMode = false;
let notchExpanded = false;
let fallTimer = null;
let tokens = null; // { access_token, refresh_token, expires_at, scope }
let status = 'logged-out'; // no-client-id | logged-out | relogin | logging-in | ok
let currentTrack = null;
let lastTrackId = null;
let pollTimer = null;
let polling = false;
let dragTimer = null;

// 곡별로 한 번만 계산/요청하도록 기억해 둠
const accentCache = new Map(); // 이미지 URL → 색
const likedCache = new Map(); // 트랙 URI → true/false
const lyricsCache = new Map(); // 트랙 id → 가사 줄 배열 또는 null

const tokenFile = () => path.join(app.getPath('userData'), 'tokens.json');

function loadConfig() {
  try {
    return JSON.parse(fs.readFileSync(path.join(__dirname, 'config.json'), 'utf8'));
  } catch {
    return {};
  }
}

function loadClientId() {
  if (process.env.SPOTIFY_CLIENT_ID) return process.env.SPOTIFY_CLIENT_ID.trim();
  return (loadConfig().clientId || '').trim();
}

function broadcast(channel, data) {
  for (const win of [widgetWin, popupWin, chipWin]) {
    if (win && !win.isDestroyed()) win.webContents.send(channel, data);
  }
}

function setStatus(s) {
  status = s;
  broadcast('status', s);
}

/* ---------------- 인증 (Authorization Code + PKCE) ---------------- */

const b64url = (buf) => buf.toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

async function requestToken(params) {
  const res = await fetch('https://accounts.spotify.com/api/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams(params),
  });
  if (!res.ok) {
    const err = new Error(`token ${res.status}: ${await res.text()}`);
    err.status = res.status;
    throw err;
  }
  const j = await res.json();
  tokens = {
    access_token: j.access_token,
    refresh_token: j.refresh_token || tokens?.refresh_token,
    expires_at: Date.now() + (j.expires_in - 60) * 1000,
    scope: j.scope || tokens?.scope || '',
  };
  fs.writeFileSync(tokenFile(), JSON.stringify(tokens));
}

// 예전 버전에서 로그인한 토큰에는 재생 조작/좋아요 권한이 없음
const hasAllScopes = (t) => SCOPES.every((s) => (t?.scope || '').split(' ').includes(s));

function refreshToken() {
  return requestToken({
    grant_type: 'refresh_token',
    refresh_token: tokens.refresh_token,
    client_id: loadClientId(),
  });
}

function login() {
  const clientId = loadClientId();
  if (!clientId) return setStatus('no-client-id');
  if (status === 'logging-in') return;
  setStatus('logging-in');

  const verifier = b64url(crypto.randomBytes(64));
  const challenge = b64url(crypto.createHash('sha256').update(verifier).digest());
  const state = b64url(crypto.randomBytes(16));

  const server = http.createServer(async (req, res) => {
    const url = new URL(req.url, REDIRECT_URI);
    if (url.pathname !== '/callback') {
      res.writeHead(404);
      return res.end();
    }
    const code = url.searchParams.get('code');
    const ok = code && url.searchParams.get('state') === state;
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end(
      `<body style="font-family:sans-serif;background:#121212;color:#fff;display:grid;place-items:center;height:100vh;margin:0">
        <h2>${ok ? '✅ 로그인 완료! 이 탭은 닫아도 돼요.' : '❌ 로그인 실패. 위젯에서 다시 시도해 주세요.'}</h2></body>`
    );
    finish();
    if (!ok) return setStatus('logged-out');
    try {
      await requestToken({
        grant_type: 'authorization_code',
        code,
        redirect_uri: REDIRECT_URI,
        client_id: clientId,
        code_verifier: verifier,
      });
      setStatus('ok');
      startPolling();
    } catch (e) {
      console.error(e);
      setStatus('logged-out');
    }
  });

  // 5분 안에 로그인 안 하면 포기
  const timeout = setTimeout(() => {
    finish();
    if (status === 'logging-in') setStatus('logged-out');
  }, 5 * 60 * 1000);

  function finish() {
    clearTimeout(timeout);
    server.close();
  }

  server.on('error', (e) => {
    console.error('콜백 서버 오류:', e.message);
    finish();
    setStatus('logged-out');
  });

  server.listen(REDIRECT_PORT, '127.0.0.1', () => {
    const q = new URLSearchParams({
      client_id: clientId,
      response_type: 'code',
      redirect_uri: REDIRECT_URI,
      code_challenge_method: 'S256',
      code_challenge: challenge,
      scope: SCOPES.join(' '),
      state,
    });
    shell.openExternal(`https://accounts.spotify.com/authorize?${q}`);
  });
}

function logout() {
  stopPolling();
  tokens = null;
  currentTrack = null;
  lastTrackId = null;
  try { fs.unlinkSync(tokenFile()); } catch {}
  broadcast('track', null);
  broadcast('lyrics', null);
  setStatus(loadClientId() ? 'logged-out' : 'no-client-id');
}

/* ---------------- Spotify API 호출 ---------------- */

async function spotifyApi(method, pathname, body) {
  if (Date.now() >= tokens.expires_at) await refreshToken();
  const call = () =>
    fetch(`https://api.spotify.com/v1${pathname}`, {
      method,
      headers: {
        Authorization: `Bearer ${tokens.access_token}`,
        ...(body && { 'Content-Type': 'application/json' }),
      },
      body: body && JSON.stringify(body),
    });
  let res = await call();
  if (res.status === 401) {
    await refreshToken();
    res = await call();
  }
  return res;
}

/* ---------------- 앨범커버 대표 색 ---------------- */

// 커버를 작게 줄여서 채도 높고 너무 어둡거나 밝지 않은 색을 고름
async function accentOf(url) {
  if (!url) return null;
  if (accentCache.has(url)) return accentCache.get(url);
  let color = null;
  try {
    const buf = Buffer.from(await (await fetch(url)).arrayBuffer());
    const img = nativeImage.createFromBuffer(buf).resize({ width: 32, height: 32 });
    const px = img.toBitmap(); // BGRA
    if (!px.length) throw new Error('이미지를 읽지 못함');
    let best = null;
    let bestScore = -1;
    let r = 0, g = 0, b = 0, n = 0;
    for (let i = 0; i < px.length; i += 4) {
      const B = px[i], G = px[i + 1], R = px[i + 2];
      r += R; g += G; b += B; n++;
      const max = Math.max(R, G, B), min = Math.min(R, G, B);
      const light = (max + min) / 2 / 255;
      const sat = max === 0 ? 0 : (max - min) / max;
      if (light < 0.15 || light > 0.9) continue;
      const score = sat * (1 - Math.abs(light - 0.55));
      if (score > bestScore) { bestScore = score; best = [R, G, B]; }
    }
    // 무채색 커버면 평균색 사용
    color = bestScore > 0.15 ? best : [r / n, g / n, b / n];
    color = brighten(color);
  } catch (e) {
    console.error('색 추출 실패:', e.message);
  }
  accentCache.set(url, color);
  return color;
}

// 어두운 배경 위에서도 잘 보이도록 명도를 끌어올림
function brighten([r, g, b]) {
  const max = Math.max(r, g, b, 1);
  const k = max < 190 ? 190 / max : 1;
  return `rgb(${[r, g, b].map((v) => Math.min(255, Math.round(v * k))).join(',')})`;
}

/* ---------------- 좋아요(라이브러리 저장) ---------------- */

async function fetchLiked(uri) {
  if (!uri?.startsWith('spotify:track:')) return null;
  if (likedCache.has(uri)) return likedCache.get(uri);
  let liked = null; // 실패해도 기억해서 1.5초마다 다시 요청하지 않음
  try {
    const res = await spotifyApi('GET', `/me/library/contains?uris=${encodeURIComponent(uri)}`);
    if (!res.ok) throw new Error(`contains ${res.status}`);
    liked = !!(await res.json())[0];
  } catch (e) {
    console.error('좋아요 확인 실패:', e.message);
  }
  likedCache.set(uri, liked);
  return liked;
}

async function toggleLike() {
  const t = currentTrack;
  if (!t?.uri?.startsWith('spotify:track:') || t.liked == null) return;
  const next = !t.liked;
  const res = await spotifyApi(next ? 'PUT' : 'DELETE', `/me/library?uris=${encodeURIComponent(t.uri)}`);
  if (!res.ok) {
    console.error('좋아요 변경 실패:', res.status, await res.text());
    return notice('좋아요를 바꾸지 못했어요');
  }
  likedCache.set(t.uri, next);
  if (currentTrack?.uri === t.uri) {
    currentTrack.liked = next;
    broadcast('track', currentTrack);
  }
}

/* ---------------- 재생 조작 ---------------- */

const CONTROLS = {
  play: ['PUT', '/me/player/play'],
  pause: ['PUT', '/me/player/pause'],
  next: ['POST', '/me/player/next'],
  previous: ['POST', '/me/player/previous'],
};

async function control(action) {
  if (!tokens) return;
  if (action === 'like') return toggleLike().catch((e) => console.error(e.message));
  // 브레인댄스에서 끌어서 정한 위치로 이동
  const request = action?.type === 'seek'
    ? ['PUT', `/me/player/seek?position_ms=${Math.max(0, Math.round(action.ms))}`]
    : CONTROLS[action];
  if (!request) return;
  try {
    const res = await spotifyApi(...request);
    if (res.status === 403) notice('재생 조작은 Spotify Premium에서만 돼요');
    else if (res.status === 404) notice('재생 중인 기기를 찾지 못했어요');
    else if (!res.ok) notice('조작에 실패했어요');
  } catch (e) {
    console.error(e.message);
    notice('조작에 실패했어요');
  }
  pollSoon();
}

function notice(text) {
  if (widgetWin && !widgetWin.isDestroyed()) widgetWin.webContents.send('notice', text);
}

/* ---------------- 가사 (LRCLIB) ---------------- */

const LRCLIB = 'https://lrclib.net/api';
const LRCLIB_HEADERS = { 'User-Agent': 'spotify-spin-widget/1.1 (desktop widget)' };

// "[01:23.45] 가사" → { t: 83450, text: '가사' }
function parseLrc(lrc) {
  const lines = [];
  for (const raw of lrc.split('\n')) {
    const stamps = [...raw.matchAll(/\[(\d+):(\d+(?:\.\d+)?)\]/g)];
    if (!stamps.length) continue;
    const text = raw.replace(/\[[^\]]*\]/g, '').trim();
    for (const [, m, s] of stamps) lines.push({ t: Math.round((Number(m) * 60 + Number(s)) * 1000), text });
  }
  return lines.sort((a, b) => a.t - b.t);
}

async function findLyrics(t) {
  const artist = t.artist.split(', ')[0];
  const sec = Math.round(t.duration / 1000);
  const q = new URLSearchParams({ track_name: t.title, artist_name: artist, album_name: t.album, duration: sec });
  let res = await fetch(`${LRCLIB}/get?${q}`, { headers: LRCLIB_HEADERS });
  if (res.ok) {
    const j = await res.json();
    if (j.syncedLyrics) return parseLrc(j.syncedLyrics);
  }
  // 앨범명/길이가 조금 달라도 찾을 수 있게 검색으로 한 번 더
  res = await fetch(`${LRCLIB}/search?${new URLSearchParams({ track_name: t.title, artist_name: artist })}`, {
    headers: LRCLIB_HEADERS,
  });
  if (!res.ok) return null;
  const hit = (await res.json())
    .filter((r) => r.syncedLyrics && Math.abs(r.duration - sec) <= 3)
    .sort((a, b) => Math.abs(a.duration - sec) - Math.abs(b.duration - sec))[0];
  return hit ? parseLrc(hit.syncedLyrics) : null;
}

async function loadLyrics(t) {
  if (!t?.id) return broadcast('lyrics', null);
  if (!lyricsCache.has(t.id)) {
    let lines = null;
    if (t.uri?.startsWith('spotify:track:')) {
      try {
        lines = await findLyrics(t);
      } catch (e) {
        console.error('가사 검색 실패:', e.message);
        return broadcast('lyrics', { id: t.id, lines: null }); // 실패는 기억하지 않음
      }
    }
    lyricsCache.set(t.id, lines);
  }
  broadcast('lyrics', { id: t.id, lines: lyricsCache.get(t.id) });
}

/* ---------------- 재생 정보 폴링 ---------------- */

function toTrack(j) {
  const item = j?.item;
  if (!item) return null;
  const images = item.album?.images || item.images || item.show?.images || [];
  return {
    id: item.id || item.uri,
    uri: item.uri,
    title: item.name,
    artist: item.artists ? item.artists.map((a) => a.name).join(', ') : item.show?.name || '',
    album: item.album?.name || '',
    image: images[0]?.url || '',
    isPlaying: !!j.is_playing,
    progress: j.progress_ms || 0,
    duration: item.duration_ms || 0,
  };
}

// 다음 폴링까지 기다릴 ms 를 반환
async function poll() {
  const res = await spotifyApi('GET', '/me/player/currently-playing?additional_types=track,episode');

  if (res.status === 429) return (Number(res.headers.get('retry-after')) || 5) * 1000;
  if (res.status === 204 || !res.ok) {
    currentTrack = null;
    broadcast('track', null);
    return POLL_MS * 2;
  }

  const t = toTrack(await res.json());
  if (t) {
    const isNew = t.id !== lastTrackId;
    if (isNew) likedCache.delete(t.uri); // Spotify 앱에서 바꿨을 수도 있으니 곡마다 새로 확인
    // 곡이 바뀌면 색과 좋아요 여부를 먼저 구한 뒤 한 번에 보냄
    [t.accent, t.liked] = await Promise.all([accentOf(t.image), fetchLiked(t.uri)]);
    t.sandy = isSandyTrack(t);
    currentTrack = t;
    broadcast('track', t);
    if (isNew) {
      lastTrackId = t.id;
      showPopup(t);
      loadLyrics(t);
      if (isChipTrack(t)) dropChip();
      else removeChip();
    }
  } else {
    currentTrack = null;
    broadcast('track', null);
  }
  return POLL_MS;
}

async function loop() {
  clearTimeout(pollTimer);
  if (polling) return;
  polling = true;
  let delay = POLL_MS;
  try {
    delay = await poll();
  } catch (e) {
    console.error(e.message);
    polling = false;
    // 리프레시 토큰이 만료/취소됨 → 다시 로그인 필요
    if (e.status === 400 || e.status === 401) return logout();
    delay = 5000;
  }
  polling = false;
  if (tokens) pollTimer = setTimeout(loop, delay);
}

// 버튼을 누른 뒤 화면이 빨리 따라오도록 곧바로 한 번 더 확인
function pollSoon() {
  if (!tokens) return;
  clearTimeout(pollTimer);
  pollTimer = setTimeout(loop, 400);
}

function startPolling() {
  stopPolling();
  loop();
}

function stopPolling() {
  clearTimeout(pollTimer);
  pollTimer = null;
}

/* ---------------- 창 ---------------- */

const webPreferences = {
  preload: path.join(__dirname, 'preload.js'),
  autoplayPolicy: 'no-user-gesture-required', // 효과음이 클릭 없이도 나오게
};

// 효과음 켜기/끄기처럼 앱이 기억할 설정
const settingsFile = () => path.join(app.getPath('userData'), 'settings.json');
function loadSettings() {
  try {
    return JSON.parse(fs.readFileSync(settingsFile(), 'utf8'));
  } catch {
    return {};
  }
}
function saveSettings(patch) {
  fs.writeFileSync(settingsFile(), JSON.stringify({ ...loadSettings(), ...patch }));
}

function createWidget() {
  widgetWin = new BrowserWindow({
    width: WIDGET_SIZE,
    height: WIDGET_SIZE,
    frame: false,
    transparent: true,
    resizable: false,
    maximizable: false,
    alwaysOnTop: true,
    hasShadow: false,
    title: 'Spotify Widget',
    enableLargerThanScreen: true, // 노치 모드에서 메뉴바 위(노치 자리)까지 올라갈 수 있게
    webPreferences,
  });
  widgetWin.on('closed', () => app.quit());
  return widgetWin.loadFile('widget.html', { query: { mode: 'widget' } });
}

/* ---------------- 노치 모드 ---------------- */
// 평소엔 노치 양옆에 작은 알약 모양, 마우스를 올리거나 곡이 바뀌면 아래로 펼쳐짐.
// 창 크기는 그대로 두고 widget.html 이 그림을 펼치고 접음. 접혀 있을 땐 알약 말고는 클릭이 뒤로 통과함.

function notchLayout() {
  const d = screen.getAllDisplays().find((x) => x.internal) || screen.getPrimaryDisplay();
  const bar = d.workArea.y - d.bounds.y; // 메뉴바 높이 (노치 있는 맥은 노치 높이와 같음)
  const menuH = bar >= 24 ? bar : 32;
  const width = NOTCH_PANEL_W + NOTCH_PAD * 2;
  return {
    x: Math.round(d.bounds.x + d.bounds.width / 2 - width / 2),
    y: d.bounds.y,
    width,
    height: NOTCH_CARD_H + 16,
    menuH,
    notchW: loadConfig().notchWidth || NOTCH_DEFAULT_W,
  };
}

const modeInfo = () => {
  if (!notchMode) return { notch: false };
  const { menuH, notchW } = notchLayout();
  return { notch: true, menuH, notchW };
};

function applyMode(notch, { remember = true } = {}) {
  notchMode = notch;
  notchExpanded = false;
  if (remember) saveSettings({ notch });
  if (notch) {
    if (remember) saveSettings({ floatBounds: widgetWin.getBounds() });
    const L = notchLayout();
    widgetWin.setAlwaysOnTop(true, 'screen-saver'); // 메뉴바보다 위
    widgetWin.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });
    widgetWin.setBounds({ x: L.x, y: L.y, width: L.width, height: L.height });
    widgetWin.setIgnoreMouseEvents(true, { forward: true });
    popupWin.hide();
    if (chipState === 'inserted') chipWin.hide(); // 접혀 있을 땐 칩도 숨김
  } else {
    const b = loadSettings().floatBounds;
    widgetWin.setAlwaysOnTop(true, 'floating');
    widgetWin.setVisibleOnAllWorkspaces(false);
    widgetWin.setIgnoreMouseEvents(false);
    widgetWin.setBounds({ x: b?.x ?? 120, y: b?.y ?? 120, width: WIDGET_SIZE, height: WIDGET_SIZE });
    if (chipState === 'inserted') {
      placeDocked();
      chipWin.showInactive();
    }
  }
  matchChipLevel();
  widgetWin.webContents.send('mode', modeInfo());
}

// 칩 창을 위젯과 같은 층에 둠 (노치 모드에선 메뉴바 위 층)
function matchChipLevel() {
  if (!chipWin || chipWin.isDestroyed()) return;
  if (notchMode) chipWin.setAlwaysOnTop(true, 'screen-saver');
  else chipWin.setAlwaysOnTop(widgetWin.isAlwaysOnTop());
  chipWin.setVisibleOnAllWorkspaces(notchMode, { visibleOnFullScreen: notchMode });
}

// 알약 위에 마우스가 있거나 펼쳐져 있을 때만 클릭을 받음
ipcMain.on('notch-interactive', (_e, on) => {
  if (notchMode) widgetWin.setIgnoreMouseEvents(!on, { forward: true });
});

// 펼쳐지면 꽂힌 칩 끝을 다시 보여주고, 접히면 숨김
ipcMain.on('notch-expanded', (_e, on) => {
  if (!notchMode) return;
  notchExpanded = on;
  if (chipState !== 'inserted') return;
  if (!on) return chipWin.hide();
  setTimeout(() => {
    if (!notchExpanded || chipState !== 'inserted') return;
    placeDocked();
    chipWin.showInactive();
    chipWin.moveTop();
  }, 380); // 카드가 다 펼쳐진 뒤에
});

function popupPosition() {
  const { workArea } = screen.getDisplayNearestPoint(screen.getCursorScreenPoint());
  return {
    x: Math.round(workArea.x + workArea.width - POPUP_SIZE - POPUP_MARGIN),
    y: Math.round(workArea.y + POPUP_MARGIN),
  };
}

function createPopup() {
  popupWin = new BrowserWindow({
    width: POPUP_SIZE,
    height: POPUP_SIZE,
    ...popupPosition(),
    frame: false,
    transparent: true,
    resizable: false,
    movable: false,
    focusable: false,
    skipTaskbar: true,
    alwaysOnTop: true,
    hasShadow: false,
    show: false,
    webPreferences,
  });
  popupWin.setAlwaysOnTop(true, 'screen-saver');
  popupWin.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });
  popupWin.setIgnoreMouseEvents(true); // 알림이 클릭을 가로막지 않도록
  return popupWin.loadFile('widget.html', { query: { mode: 'popup' } });
}

function showPopup(track) {
  // 노치 모드에선 알림 카드 대신 노치가 잠깐 펼쳐짐
  if (notchMode) return widgetWin.webContents.send('peek');
  if (!popupWin || popupWin.isDestroyed()) return;
  const { x, y } = popupPosition();
  popupWin.setBounds({ x, y, width: POPUP_SIZE, height: POPUP_SIZE });
  popupWin.webContents.send('popup', track);
  popupWin.showInactive();
}

/* ---------------- 카프리 칩 ---------------- */

// 대소문자, 문장부호, 악센트(ł, ż 등)를 무시하고 비교
const normalize = (s) =>
  (s || '')
    .toLowerCase()
    .replace(/ł/g, 'l')
    .normalize('NFD')
    .replace(/\p{M}/gu, '')
    .replace(/[^\p{L}\p{N}]+/gu, ' ')
    .trim();

// 작품에 나온 곡 목록 (게임 라디오·싱글 등 다른 앨범에 실린 곡 포함)
// chip-songs.json: 엣지러너 2, sandy-songs.json: 엣지러너 1
function loadSongs(file) {
  try {
    return JSON.parse(fs.readFileSync(path.join(__dirname, file), 'utf8'));
  } catch {
    return [];
  }
}

// " - Remastered", "(feat. ...)" 같은 꼬리를 떼고 제목만 비교, 가수도 같이 확인
function inSongList(t, file) {
  const title = normalize(t.title.split(/\s[-–]\s|\s[([]/)[0]);
  const artist = normalize(t.artist);
  return loadSongs(file).some(
    (s) => normalize(s.title) === title && s.artists.some((a) => artist.includes(normalize(a)))
  );
}

function matches(t, words) {
  const hay = normalize(`${t.album} ${t.title}`);
  return words.some((w) => hay.includes(normalize(w)));
}

const isChipTrack = (t) =>
  matches(t, loadConfig().chipKeywords || DEFAULT_CHIP_KEYWORDS) || inSongList(t, 'chip-songs.json');
const isSandyTrack = (t) =>
  !isChipTrack(t) &&
  (matches(t, loadConfig().sandyKeywords || DEFAULT_SANDY_KEYWORDS) || inSongList(t, 'sandy-songs.json'));

function sendChip(state) {
  if (widgetWin && !widgetWin.isDestroyed()) widgetWin.webContents.send('chip', state);
}

function createChip() {
  chipWin = new BrowserWindow({
    width: CHIP_W,
    height: CHIP_H,
    frame: false,
    transparent: true,
    resizable: false,
    maximizable: false,
    skipTaskbar: true,
    alwaysOnTop: true,
    hasShadow: false,
    show: false,
    // 포커스가 없어도 떨어지기/꽂히기 애니메이션이 느려지지 않게
    webPreferences: { ...webPreferences, backgroundThrottling: false },
  });
  // 위젯과 같은 층에 두고, 다른 화면(데스크톱/전체화면 앱)으로 가면 따라오지 않게 함
  return chipWin.loadFile('chip.html');
}

// 화면 위에서 위젯 옆으로 떨어져서 한 번 튕김
function dropChip() {
  if (!chipWin || chipWin.isDestroyed() || chipState !== 'none') return;
  const wb = widgetWin.getBounds();
  const { workArea: wa } = screen.getDisplayMatching(wb);
  // 홈이 오른쪽에 있으니 위젯 오른쪽에 떨어뜨림 (자리가 없으면 왼쪽)
  const rightRoom = wa.x + wa.width - (wb.x + wb.width) >= CHIP_W + 10;
  const x = Math.round(rightRoom ? wb.x + wb.width + 10 : Math.max(wa.x, wb.x - CHIP_W - 10));
  const floor = Math.round(Math.min(wb.y + wb.height - CHIP_H, wa.y + wa.height - CHIP_H));
  let y = wa.y - CHIP_H;
  let vy = 0;
  let bounced = 0;

  chipState = 'falling';
  matchChipLevel();
  chipWin.setBounds({ x, y, width: CHIP_W, height: CHIP_H });
  chipWin.webContents.send('chip-show');
  chipWin.showInactive();
  chipWin.moveTop(); // 같은 층 안에서는 위젯보다 앞에
  sendChip('ready');

  clearInterval(fallTimer);
  fallTimer = setInterval(() => {
    if (chipWin.isDestroyed()) return clearInterval(fallTimer); // 종료 중
    vy += 2.2;
    y += vy;
    if (y >= floor) {
      y = floor;
      vy = -vy * 0.35;
      if (++bounced === 1) chipWin.webContents.send('chip-land');
      if (Math.abs(vy) < 3) {
        clearInterval(fallTimer);
        chipState = 'dropped';
      }
    }
    chipWin.setBounds({ x, y: Math.round(y), width: CHIP_W, height: CHIP_H });
  }, 16);
}

function removeChip() {
  clearInterval(fallTimer);
  if (chipDragging) {
    chipDragging = false;
    clearInterval(dragTimer);
  }
  setSlotted(false);
  if (chipWin && !chipWin.isDestroyed()) chipWin.hide();
  if (chipState !== 'none') sendChip('off');
  chipState = 'none';
}

/* ---------------- IPC ---------------- */

ipcMain.handle('get-state', () => ({
  status,
  mode: modeInfo(),
  sfx: loadSettings().sfx !== false,
  track: currentTrack,
  lyrics: currentTrack && lyricsCache.has(currentTrack.id)
    ? { id: currentTrack.id, lines: lyricsCache.get(currentTrack.id) }
    : null,
}));
ipcMain.on('login', login);
ipcMain.on('control', (_e, action) => control(action));
ipcMain.on('popup-done', () => popupWin && !popupWin.isDestroyed() && popupWin.hide());

// 창 드래그: -webkit-app-region 을 쓰면 우클릭 메뉴가 막혀서 직접 구현
function dragWindow(win, onMove) {
  clearInterval(dragTimer);
  const { x: wx, y: wy, width, height } = win.getBounds();
  const c = screen.getCursorScreenPoint();
  const off = { x: c.x - wx, y: c.y - wy };
  dragTimer = setInterval(() => {
    const p = screen.getCursorScreenPoint();
    win.setBounds({ x: p.x - off.x, y: p.y - off.y, width, height });
    onMove?.();
  }, 10);
}

// 위젯을 옮기면 꽂혀 있는 칩도 같이 따라옴
ipcMain.on('drag-start', () => {
  if (notchMode) return; // 노치 모드에선 자리 고정
  dragWindow(widgetWin, () => chipState === 'inserted' && placeDocked());
});
ipcMain.on('drag-end', () => clearInterval(dragTimer));

/* ---------------- 칩을 손으로 꽂고 뽑기 ---------------- */
// 칩은 위젯을 통과하지 못하고, 오른쪽 홈 높이에 맞춰 왼쪽으로 밀어야만 들어감 (USB 꽂듯이)
// 칩 위치는 단자 끝의 x(tip)와 칩 가운데 높이(cy)로 다룸

let chipHover = false;
let chipDragging = false;
let chipSlotted = false; // 단자가 홈에 걸려 있음 (넣는 중 / 꽂힘 / 빼는 중)
let chipPos = { tip: 0, cy: 0 };
let chipGrab = { x: 0, y: 0 }; // 잡은 곳과 칩 위치 차이

function widgetGeom() {
  const w = widgetWin.getBounds();
  if (notchMode) {
    // 노치 아래로 펼쳐진 카드 기준
    const left = w.x + NOTCH_PAD;
    const right = left + NOTCH_PANEL_W;
    return { left, right, top: w.y, bottom: w.y + NOTCH_CARD_H, slotX: right, slotY: w.y + NOTCH_CARD_H / 2 };
  }
  return {
    left: w.x + CARD_INSET,
    right: w.x + w.width - CARD_INSET,
    top: w.y + CARD_INSET,
    bottom: w.y + w.height - CARD_INSET,
    slotX: w.x + w.width - CARD_INSET, // 카드 오른쪽 변 = 홈 입구
    slotY: w.y + w.height / 2,
  };
}

function setSlotted(on) {
  if (chipSlotted === on) return;
  chipSlotted = on;
  if (!on && chipWin && !chipWin.isDestroyed()) chipWin.webContents.send('chip-mode', { slotted: false });
}

function placeChip(tip, cy) {
  chipPos = { tip, cy };
  if (chipSlotted) {
    // 창 왼쪽 끝을 홈 입구에 붙여서, 홈 안으로 들어간 부분은 창 밖으로 잘려 안 보이게 함
    const { slotX } = widgetGeom();
    const width = chipState === 'inserted' && !chipDragging ? CHIP_DOCK_W : CHIP_W;
    chipWin.setBounds({ x: Math.round(slotX), y: Math.round(cy - CHIP_H / 2), width, height: CHIP_H });
    chipWin.webContents.send('chip-mode', { slotted: true, left: Math.round(tip - slotX) });
  } else {
    chipWin.setBounds({
      x: Math.round(tip - CHIP_BOX_X),
      y: Math.round(cy - CHIP_BOX_Y - CHIP_THICK / 2),
      width: CHIP_W,
      height: CHIP_H,
    });
  }
}

function placeDocked() {
  const g = widgetGeom();
  placeChip(g.slotX - CHIP_DEPTH, g.slotY);
}

// 칩이 위젯 카드와 겹치려 하면, 원래 있던 쪽 가장자리에 막혀서 그 변을 따라 미끄러지게 함
// (마우스를 멀리 끌어도 위젯을 뚫거나 넘어가지 않고, 돌아가야만 반대편으로 갈 수 있음)
function pushOutOfWidget(tip, cy, g, prev) {
  const half = CHIP_THICK / 2;
  const rowsOverlap = cy + half > g.top && cy - half < g.bottom;
  const colsOverlap = tip + CHIP_LEN > g.left && tip < g.right;
  // 한쪽에서 위젯 안으로 들어오거나 위젯을 건너뛰려 하면 그쪽 가장자리에서 멈춤
  if (prev.tip >= g.right && tip < g.right && rowsOverlap) return [g.right, cy];
  if (prev.tip + CHIP_LEN <= g.left && tip + CHIP_LEN > g.left && rowsOverlap) return [g.left - CHIP_LEN, cy];
  if (prev.cy + half <= g.top && cy + half > g.top && colsOverlap) return [tip, g.top - half];
  if (prev.cy - half >= g.bottom && cy - half < g.bottom && colsOverlap) return [tip, g.bottom + half];
  if (!rowsOverlap || !colsOverlap) return [tip, cy];
  // 이미 겹쳐 있던 경우(위젯을 칩 위로 옮겼을 때 등): 가장 가까운 쪽으로 밀어냄
  const moves = [[g.right - tip, 0], [g.left - tip - CHIP_LEN, 0], [0, g.top - cy - half], [0, g.bottom - cy + half]];
  const [dx, dy] = moves.reduce((a, m) => (Math.abs(m[0] + m[1]) < Math.abs(a[0] + a[1]) ? m : a));
  return [tip + dx, cy + dy];
}

function chipDragTick() {
  if (chipWin.isDestroyed()) return clearInterval(dragTimer);
  const p = screen.getCursorScreenPoint();
  let tip = p.x - chipGrab.x;
  let cy = p.y - chipGrab.y;
  const g = widgetGeom();

  if (!chipSlotted) {
    const nearSlot = Math.abs(cy - g.slotY) < SLOT_SNAP && tip > g.slotX - 6 && tip < g.slotX + 30;
    if (nearSlot) cy = g.slotY; // 홈 높이에 착 붙음
    // 홈 입구 오른쪽에서 왼쪽으로 밀어 넣을 때만 홈에 걸림
    if (nearSlot && tip <= g.slotX && chipPos.tip >= g.slotX - 6) setSlotted(true);
  }

  if (chipSlotted) {
    cy = g.slotY;
    const depth = g.slotX - tip;
    if (depth >= CHIP_DEPTH && chipState !== 'inserted') return dockChip();
    if (depth < -8) {
      // 끝까지 빼냄
      if (chipState === 'inserted') undockChip();
      setSlotted(false);
    } else {
      tip = g.slotX - Math.min(CHIP_DEPTH, Math.max(0, depth));
    }
  }
  if (!chipSlotted) [tip, cy] = pushOutOfWidget(tip, cy, g, chipPos);
  placeChip(tip, cy);

  if (chipState !== 'inserted') {
    const hover = chipSlotted || (Math.abs(cy - g.slotY) < 40 && Math.abs(tip - g.slotX) < 60);
    if (hover !== chipHover) sendChip((chipHover = hover) ? 'hover' : 'ready');
  }
}

// 끝까지 밀어 넣음: 딸깍 꽂히고 카프리 연출 시작
function dockChip() {
  clearInterval(dragTimer);
  chipDragging = false;
  chipState = 'inserted';
  chipHover = false;
  placeDocked();
  chipWin.webContents.send('chip-docked');
  sendChip('on');
}

// 끝까지 뽑아냄: 카프리 연출 끝, 칩은 다시 자유롭게
function undockChip() {
  chipState = 'dropped';
  chipWin.webContents.send('chip-undocked');
  sendChip('off');
  sendChip('ready');
}

ipcMain.on('chip-drag-start', () => {
  if (!['falling', 'dropped', 'inserted'].includes(chipState)) return;
  clearInterval(fallTimer);
  if (chipState === 'falling') chipState = 'dropped';
  if (!chipSlotted) {
    const b = chipWin.getBounds();
    chipPos = { tip: b.x + CHIP_BOX_X, cy: b.y + CHIP_BOX_Y + CHIP_THICK / 2 };
  }
  const c = screen.getCursorScreenPoint();
  chipGrab = { x: c.x - chipPos.tip, y: c.y - chipPos.cy };
  chipDragging = true;
  chipWin.moveTop();
  if (chipState === 'inserted') placeChip(chipPos.tip, chipPos.cy); // 뺄 공간만큼 창을 다시 넓힘
  clearInterval(dragTimer);
  dragTimer = setInterval(chipDragTick, 10);
});

ipcMain.on('chip-drag-end', () => {
  if (!chipDragging) return;
  chipDragging = false;
  clearInterval(dragTimer);
  if (chipState === 'inserted') return placeDocked(); // 덜 뺐으면 다시 쏙 들어감
  if (chipSlotted) {
    // 덜 넣고 놓으면 튕겨 나옴
    setSlotted(false);
    const g = widgetGeom();
    placeChip(g.slotX + 6, g.slotY);
  }
  chipHover = false;
  sendChip('ready');
});

ipcMain.on('context-menu', () => {
  Menu.buildFromTemplate([
    {
      label: '노치 모드',
      type: 'checkbox',
      checked: notchMode,
      click: () => applyMode(!notchMode),
    },
    {
      label: '항상 위에 표시',
      type: 'checkbox',
      enabled: !notchMode,
      checked: widgetWin.isAlwaysOnTop(),
      click: (item) => {
        widgetWin.setAlwaysOnTop(item.checked);
        chipWin.setAlwaysOnTop(item.checked); // 칩도 위젯과 같은 층으로
      },
    },
    { label: '알림 미리보기', enabled: !!currentTrack, click: () => showPopup(currentTrack) },
    chipState === 'none'
      ? { label: '카프리 칩 떨어뜨리기', click: dropChip }
      : { label: '카프리 칩 뽑기', click: removeChip },
    { label: '산데비스탄 켜기', click: () => widgetWin.webContents.send('sandy') },
    {
      label: '효과음',
      type: 'checkbox',
      checked: loadSettings().sfx !== false,
      click: (item) => {
        saveSettings({ sfx: item.checked });
        broadcast('sfx', item.checked);
      },
    },
    { type: 'separator' },
    tokens ? { label: '로그아웃', click: logout } : { label: 'Spotify 로그인', click: login },
    { label: '종료', click: () => app.quit() },
  ]).popup({ window: widgetWin });
});

/* ---------------- 시작 ---------------- */

app.whenReady().then(async () => {
  await Promise.all([createWidget(), createPopup(), createChip()]);
  if (loadSettings().notch) applyMode(true, { remember: false });

  if (!loadClientId()) return setStatus('no-client-id');

  try {
    tokens = JSON.parse(fs.readFileSync(tokenFile(), 'utf8'));
  } catch {
    tokens = null;
  }
  if (tokens?.refresh_token && !hasAllScopes(tokens)) {
    // 새 기능에 필요한 권한이 없어서 한 번 다시 로그인해야 함
    tokens = null;
    setStatus('relogin');
  } else if (tokens?.refresh_token) {
    setStatus('ok');
    startPolling();
  } else {
    setStatus('logged-out');
  }
});

app.on('window-all-closed', () => app.quit());
app.on('before-quit', () => {
  // 창이 닫힌 뒤에 타이머가 창을 건드리지 않도록
  clearInterval(fallTimer);
  clearInterval(dragTimer);
  stopPolling();
});
