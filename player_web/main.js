import * as THREE from 'three';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';
import { loadAvatarAssets, createAvatar, loadRocketboxAssets, createRocketboxAvatar } from './avatars.js';
const REALISTIC = new URLSearchParams(location.search).get('avatars') !== 'quaternius';

const Q = new URLSearchParams(location.search);
const EXPORT = (Q.get('export') || '../export/alpine_summit_10m').replace(/\/$/, '');
const $ = id => document.getElementById(id);
const stage = $('stage'), video = $('video'), canvas = $('gl');
const num = (k, d) => (Q.has(k) ? parseFloat(Q.get(k)) : d);

// ---------------------------------------------------------------- helpers
const paceToMps = s => { const [m, sec] = s.split(':').map(Number); return 1000 / (m * 60 + (sec || 0)); };
const secKmToStr = s => `${Math.floor(s / 60)}:${String(Math.round(s % 60)).padStart(2, '0')}`;
const fmtTime = t => `${Math.floor(t / 60)}:${String(Math.floor(t % 60)).padStart(2, '0')}`;
const sstep = (a, b, x) => { const t = Math.min(1, Math.max(0, (x - a) / (b - a))); return t * t * (3 - 2 * t); };

// ---------------------------------------------------------------- data
const [cam, route] = await Promise.all([fetch(`${EXPORT}/camera.json`).then(r => r.json()), fetch(`${EXPORT}/route.json`).then(r => r.json())]);
const F = cam.frames, NF = F.t.length, FPS = cam.fps, SPEED0 = cam.speed_mps;
const ASPECT = cam.width / cam.height;
const HALF_W = Math.min(route.road_left, route.road_right);
const MAX_LANE = HALF_W - 0.22;

function routeAt(s, out = {}) {
  const n = route.s.length - 1;
  s = Math.min(n, Math.max(0, s)); const i = Math.min(n - 1, Math.floor(s)), f = s - i;
  const L = (a) => a[i] + (a[i + 1] - a[i]) * f;
  out.x = L(route.x); out.y = L(route.y); out.z = L(route.z);
  let lx = L(route.lx), lz = L(route.lz); const k = Math.hypot(lx, lz) || 1; out.lx = lx / k; out.lz = lz / k;
  return out;
}
const _a = {}, _b = {};
function frameOfMediaTime(mt) { return Math.min(NF - 1, Math.max(0, Math.round(mt * FPS))); }

// ---------------------------------------------------------------- three
const renderer = new THREE.WebGLRenderer({ canvas, antialias: true, alpha: true, premultipliedAlpha: true, preserveDrawingBuffer: Q.has('debug') });
renderer.setClearColor(0x000000, 0);
renderer.outputColorSpace = THREE.SRGBColorSpace;
renderer.toneMapping = THREE.ACESFilmicToneMapping;
renderer.toneMappingExposure = num('exposure', 0.9);
renderer.shadowMap.enabled = Q.get('shadows') !== '0';
renderer.shadowMap.type = THREE.PCFSoftShadowMap;
const scene = new THREE.Scene();
const camera = new THREE.PerspectiveCamera(cam.fov_y_deg, ASPECT, cam.near, cam.far);
camera.rotation.order = 'YXZ';
const sun = new THREE.DirectionalLight(0xffffff, 3);
sun.castShadow = renderer.shadowMap.enabled;
sun.shadow.mapSize.set(2048, 2048);
const SH = 40; Object.assign(sun.shadow.camera, { left: -SH, right: SH, top: SH, bottom: -SH, near: 1, far: 300 });
sun.shadow.bias = -0.0004; sun.shadow.normalBias = 0.03; sun.shadow.radius = 3;
scene.add(sun, sun.target);
const hemi = new THREE.HemisphereLight(0xcfe0ff, 0x8a7f72, num('hemi', 1.0));
scene.add(hemi);

// depth-only occluder (terrain + road); lowered a few cm so feet never z-fight with the road surface
const occ = new THREE.Group(); occ.name = 'occluder'; scene.add(occ);
const occMat = new THREE.MeshBasicMaterial({ colorWrite: false, depthWrite: true, side: THREE.DoubleSide, polygonOffset: true, polygonOffsetFactor: 1, polygonOffsetUnits: 1 });
new GLTFLoader().load(`${EXPORT}/occluder.glb`, g => {
  g.scene.traverse(o => { if (o.isMesh) { o.material = occMat; o.renderOrder = -10; o.castShadow = false; o.receiveShadow = false; } });
  g.scene.position.y = -num('occdrop', 0.05);
  occ.add(g.scene);
});

// shadow-catcher ribbon along the whole route (invisible except for shadows)
{
  const n = route.s.length, w = 1.7, pos = new Float32Array(n * 6), idx = [];
  for (let i = 0; i < n; i++) {
    const lx = route.lx[i], lz = route.lz[i], x = route.x[i], y = route.y[i] + 0.015, z = route.z[i];
    pos.set([x + lx * w, y, z + lz * w, x - lx * w, y, z - lz * w], i * 6);
    if (i < n - 1) idx.push(i * 2, i * 2 + 1, i * 2 + 2, i * 2 + 1, i * 2 + 3, i * 2 + 2);
  }
  const geo = new THREE.BufferGeometry(); geo.setAttribute('position', new THREE.BufferAttribute(pos, 3)); geo.setIndex(idx);
  const m = new THREE.Mesh(geo, new THREE.ShadowMaterial({ opacity: 0.4, depthWrite: false, side: THREE.DoubleSide }));
  m.receiveShadow = true; m.renderOrder = 1; m.frustumCulled = false; scene.add(m);
}

// blob contact shadow texture
const blobTex = (() => {
  const c = document.createElement('canvas'); c.width = c.height = 128; const g = c.getContext('2d');
  const r = g.createRadialGradient(64, 64, 0, 64, 64, 64);
  r.addColorStop(0, 'rgba(0,0,0,0.75)'); r.addColorStop(0.45, 'rgba(0,0,0,0.38)'); r.addColorStop(1, 'rgba(0,0,0,0)');
  g.fillStyle = r; g.fillRect(0, 0, 128, 128);
  const t = new THREE.CanvasTexture(c); t.colorSpace = THREE.SRGBColorSpace; return t;
})();

// ---------------------------------------------------------------- pacers
const RB_MODELS = ['Sports_Female_02', 'Sports_Male_04', 'Female_Party_02', 'Sports_Male_02', 'Sports_Male_04'];
const SPECS = [
  { name: 'Ava', gender: 'Female', skin: 'light', hair: ['Hair_Buns'], hairColor: '#b07a46', shirt: '#e0312b', shorts: '#222833', shoes: '#f4f4f4', lane: -0.38, scale: 0.98 },
  { name: 'Ben', gender: 'Male', skin: 'dark', hair: ['Hair_Buzzed'], hairColor: '#2a2018', shirt: '#2a73e0', shorts: '#e8e8e8', shoes: '#ffb300', lane: 0.32, scale: 1.02 },
  { name: 'Cleo', gender: 'Female', skin: 'dark', hair: ['Hair_Long'], hairColor: '#3a2a20', shirt: '#f2c230', shorts: '#2a2a35', shoes: '#e0312b', lane: 0.0, scale: 0.97 },
  { name: 'Dan', gender: 'Male', skin: 'light', hair: ['Hair_SimpleParted', 'Hair_Beard'], hairColor: '#7a4b25', shirt: '#2fb36a', shorts: '#1c2430', shoes: '#2a73e0', lane: -0.22, scale: 1.04 },
  { name: 'Eli', gender: 'Male', skin: 'light', hair: ['Hair_SimpleParted'], hairColor: '#d9b46c', shirt: '#f08a24', shorts: '#2b2f3a', shoes: '#f4f4f4', lane: 0.18, scale: 1.0 },
];
const DEFAULT_PACERS = '5:30@-30,5:45@20,6:15@45,6:30@12,6:00@70';
const pacerCfg = (Q.get('pacers') || DEFAULT_PACERS).split(',').map(t => { const [p, o] = t.split('@'); return { pace: p, v: paceToMps(p), off: parseFloat(o || '0') }; });
const pacers = [];
const state = { userPaceSec: 360, playing: false, lastMT: null, userS: 0, frame: 0, ready: false, camLat: 0, cached: null };
if (Q.get('speed')) state.userPaceSec = (([m, s]) => m * 60 + (s || 0))(Q.get('speed').split(':').map(Number));

let assets = null;
const rowEls = [];
async function buildPacers() {
  assets = REALISTIC ? await loadRocketboxAssets() : await loadAvatarAssets();
  pacerCfg.slice(0, SPECS.length).forEach((cfg, i) => {
    const spec = SPECS[i];
    const av = REALISTIC ? createRocketboxAvatar(assets, { ...spec, model: RB_MODELS[i] }) : createAvatar(assets, spec);
    av.root.visible = false; scene.add(av.root);
    const blob = new THREE.Mesh(new THREE.PlaneGeometry(1.5, 1.5), new THREE.MeshBasicMaterial({ map: blobTex, transparent: true, depthWrite: false, polygonOffset: true, polygonOffsetFactor: -2, polygonOffsetUnits: -2 }));
    blob.renderOrder = 2; blob.visible = false; scene.add(blob);
    pacers.push({ ...cfg, spec, av, blob, s: 0, lane: spec.lane, curLane: spec.lane, side: 1, phase: i * 0.37, gap: 0, shown: false });
  });
  $('msg').style.display = 'none';
}

function initPacers(userS) { for (const p of pacers) p.s = userS + p.off; }

// ---------------------------------------------------------------- per-frame render (called with the PRESENTED frame's mediaTime)
const _v = new THREE.Vector3(), _q = new THREE.Quaternion(), _up = new THREE.Vector3(0, 1, 0), _n = new THREE.Vector3();
function applyCamera(i) {
  camera.position.set(F.px[i], F.py[i], F.pz[i]);
  camera.quaternion.set(F.qx[i], F.qy[i], F.qz[i], F.qw[i]);
  camera.updateMatrixWorld(true);
}
function applyLight(i) {
  const d = new THREE.Vector3(F.sun_dx[i], F.sun_dy[i], F.sun_dz[i]).normalize();
  sun.color.setRGB(F.sun_r[i], F.sun_g[i], F.sun_b[i]);
  sun.intensity = F.sun_energy[i] * Math.PI * num('sun', 1.0);
  // light + shadow frustum follow the camera so shadows stay sharp near the viewer
  _v.set(F.px[i], F.py[i], F.pz[i]);
  camera.getWorldDirection(_n); _n.y = 0; _n.normalize();
  sun.target.position.copy(_v).addScaledVector(_n, 28); sun.target.position.y -= 1.5;
  sun.position.copy(sun.target.position).addScaledVector(d, 120);
  sun.target.updateMatrixWorld();
}

function renderFrame(mt) {
  if (!state.ready) return;
  const i = frameOfMediaTime(mt);
  const sCam = F.s[i];
  // --- pacer clock: distance advances per *video* time delta scaled by playbackRate => real-time speed
  if (state.lastMT === null) { initPacers(sCam); state.userSPrev = sCam; }
  else {
    const dvt = mt - state.lastMT, r = video.playbackRate || 1;
    if (dvt > 0 && dvt < 0.5) { for (const p of pacers) p.s += (p.v / r) * dvt; }
    else if (dvt !== 0) { const ds = sCam - state.userSPrev; for (const p of pacers) p.s += ds; } // seek: keep gaps
  }
  state.lastMT = mt; state.userSPrev = sCam; state.userS = sCam; state.frame = i;
  state.mt = mt;

  applyCamera(i); applyLight(i);
  // camera lateral offset relative to the route (for passing logic)
  routeAt(sCam, _a);
  state.camLat = (F.px[i] - _a.x) * _a.lx + (F.pz[i] - _a.z) * _a.lz;
  const camFwd = camera.getWorldDirection(new THREE.Vector3());

  for (const p of pacers) {
    const d = p.s - sCam; p.gap = d;
    const visible = d > -0.8 && d < 250;
    p.shown = visible;
    p.av.root.visible = visible; p.blob.visible = visible;
    if (!visible) continue;
    // lane: stay in the trail; when within ~3 m of the camera move to the side opposite the camera
    const w = 1 - sstep(1.5, 4.5, Math.abs(d));
    if (w < 0.02) p.side = state.camLat > 0.02 ? -1 : 1;
    const lane = p.lane * (1 - w) + p.side * MAX_LANE * w; p.laneNow = lane;
    routeAt(p.s, _a); routeAt(p.s + 1, _b);
    const x = _a.x + _a.lx * lane, z = _a.z + _a.lz * lane, y = _a.y;
    const fx = _b.x - _a.x, fz = _b.z - _a.z;
    p.av.root.position.set(x, y, z);
    p.av.root.rotation.y = Math.atan2(fx, fz);
    // distance-driven animation: phase locked to ground covered => cadence proportional to speed, no sliding
    const clipV = p.av.clipSpeed || assets.clipSpeed, D = p.av.duration;
    p.av.mixer.setTime(((p.s / clipV + p.phase * D) % D + D) % D);
    // blob shadow on the ground following the slope
    const ty = _b.y - _a.y, tl = Math.hypot(fx, fz) || 1;
    _n.set(-fx / tl * ty, 1, -fz / tl * ty).normalize(); // slope normal (lateral slope ignored)
    p.blob.position.set(x, y + 0.03, z);
    p.blob.quaternion.setFromUnitVectors(new THREE.Vector3(0, 0, 1), _n); // plane faces +Z -> align with normal
    p.blob.quaternion.premultiply(new THREE.Quaternion().setFromAxisAngle(_up, 0));
    p.blob.scale.setScalar(1.0 + 0.0 * w);
  }
  renderer.render(scene, camera);
  updateHud(i);
}

// ---------------------------------------------------------------- HUD
function updateHud(i) {
  const sec = state.userPaceSec;
  $('hPace').textContent = `${secKmToStr(sec)} /km`;
  $('hDist').textContent = `${(F.s[i] / 1000).toFixed(2)} km`;
  $('hTime').textContent = fmtTime(F.t[i]);
  $('hInc').textContent = `${F.incline[i].toFixed(1)} %`;
  if (!seekDrag) $('seek').value = i;
  const html = [];
  const sorted = [...pacers].sort((a, b) => b.gap - a.gap);
  const ahead = sorted.filter(p => p.gap > -0.8), behind = sorted.filter(p => p.gap <= -0.8);
  html.push('<h4>Pacers</h4>');
  const row = (p, cls) => `<div class="row ${cls}"><span class="dot" style="background:${p.spec.shirt}"></span><span class="nm">${p.spec.name} <small style="color:var(--dim)">${p.pace}</small></span><span class="gap">${p.gap >= 0 ? '+' : '−'}${Math.abs(p.gap).toFixed(0)} m</span></div>`;
  for (const p of ahead) html.push(row(p, p.gap > 250 ? 'far' : ''));
  if (behind.length) { html.push('<div class="sep"></div><h4>Behind</h4>'); for (const p of behind) html.push(row(p, 'behind')); }
  const s = html.join('');
  if (s !== state.lastHtml) { $('pacers').innerHTML = s; state.lastHtml = s; }
}

// ---------------------------------------------------------------- sync loop
const hasRVFC = 'requestVideoFrameCallback' in HTMLVideoElement.prototype;
let lastRvfc = 0;
function guarded(mt) { try { renderFrame(mt); } catch (e) { console.error(e); } }
function loop() {
  // primary: render inside the video-frame callback with the presented frame's mediaTime
  video.requestVideoFrameCallback((now, meta) => { lastRvfc = performance.now(); loop(); guarded(meta.mediaTime); });
}
// fallback (browsers without rVFC, or a compositor that does not deliver it): rAF + currentTime
function rafLoop() {
  requestAnimationFrame(rafLoop);
  if (!video.paused && (!hasRVFC || performance.now() - lastRvfc > 250)) guarded(video.currentTime);
}

// ---------------------------------------------------------------- layout / controls
function layout() {
  const W = innerWidth, H = innerHeight;
  let w = W, h = W / ASPECT; if (h > H) { h = H; w = H * ASPECT; }
  Object.assign(stage.style, { width: w + 'px', height: h + 'px', left: (W - w) / 2 + 'px', top: (H - h) / 2 + 'px' });
  const dpr = Math.min(devicePixelRatio || 1, 2);
  renderer.setPixelRatio(dpr); renderer.setSize(w, h, false);
  camera.aspect = ASPECT; camera.updateProjectionMatrix();
  stage.style.fontSize = Math.max(11, Math.round(w / 100)) + 'px';
  if (state.ready) renderFrame(state.mt ?? video.currentTime);
}
addEventListener('resize', layout);

function setPace(sec) {
  state.userPaceSec = Math.min(540, Math.max(240, sec));
  $('pace').value = state.userPaceSec; $('paceLbl').textContent = secKmToStr(state.userPaceSec);
  video.playbackRate = (1000 / state.userPaceSec) / SPEED0;
  if (state.ready && state.mt !== undefined) updateHud(state.frame);
}
let seekDrag = false;
function seekFrame(n) { video.currentTime = (Math.min(NF - 1, Math.max(0, n)) + 0.5) / FPS; }
function togglePlay() { if (video.paused) video.play(); else video.pause(); }
function toggleHud() { document.body.classList.toggle('hidden-hud'); }
video.addEventListener('play', () => $('bPlay').textContent = 'Pause');
video.addEventListener('pause', () => $('bPlay').textContent = 'Play');
video.addEventListener('seeked', () => { if (state.ready) renderFrame(video.currentTime); });
$('bPlay').onclick = togglePlay; $('bHud').onclick = toggleHud;
$('pace').oninput = e => setPace(+e.target.value);
$('seek').max = NF - 1;
$('seek').addEventListener('input', e => { seekDrag = true; seekFrame(+e.target.value); });
$('seek').addEventListener('change', () => { seekDrag = false; });
addEventListener('keydown', e => {
  if (e.target.tagName === 'INPUT' && e.key === ' ') e.target.blur();
  if (e.key === ' ') { e.preventDefault(); togglePlay(); }
  else if (e.key === 'h' || e.key === 'H') toggleHud();
  else if (e.key === '+' || e.key === '=') setPace(state.userPaceSec - 5);   // faster
  else if (e.key === '-' || e.key === '_') setPace(state.userPaceSec + 5);   // slower
  else if (e.key === 'ArrowRight') seekFrame(state.frame + 5 * FPS);
  else if (e.key === 'ArrowLeft') seekFrame(state.frame - 5 * FPS);
  else if (e.key === 'r' || e.key === 'R') { initPacers(state.userS); }
});
if (Q.get('hud') === '0') document.body.classList.add('hidden-hud');

// ---------------------------------------------------------------- start
video.src = `${EXPORT}/video.mp4`;
await new Promise(res => { if (video.readyState >= 2) res(); else video.addEventListener('loadeddata', res, { once: true }); });
layout();
await buildPacers();
state.ready = true;
setPace(state.userPaceSec);
if (hasRVFC) loop();
rafLoop();
const startFrame = Q.has('frame') ? num('frame', 0) : Q.has('t') ? Math.round(num('t', 0) * FPS) : 0;
if (startFrame > 0) seekFrame(startFrame);
await new Promise(r => setTimeout(r, 50));
if (!Q.has('frame') && Q.get('autoplay') !== '0') video.play().catch(() => { $('msg').textContent = 'Click or press Space to play'; $('msg').style.display = ''; });
else renderFrame(video.currentTime);
video.addEventListener('playing', () => { $('msg').style.display = 'none'; });
stage.addEventListener('click', () => { if ($('msg').style.display !== 'none') { $('msg').style.display = 'none'; video.play(); } });

// ---------------------------------------------------------------- debug / verification API
async function snapshot(name, w = cam.width, h = cam.height) {
  // composite video + overlay at full export resolution and POST it to the debug server (PLAYER_DEBUG=1 python3 player_web/serve.py)
  const c = document.createElement('canvas'); c.width = w; c.height = h; const g = c.getContext('2d');
  const old = renderer.getPixelRatio(); renderer.setPixelRatio(1); renderer.setSize(w, h, false);
  renderFrame(state.mt ?? video.currentTime);
  g.drawImage(video, 0, 0, w, h); g.drawImage(canvas, 0, 0, w, h);
  renderer.setPixelRatio(old); layout();
  const blob = await new Promise(r => c.toBlob(r, 'image/png'));
  const r = await fetch(`/__save/${name}.png`, { method: 'POST', body: blob });
  return r.status;
}
window.__player = { snapshot, THREE, scene, camera, renderer, video, state, pacers, F, route, routeAt, renderFrame, seekFrame, initPacers, occ, get assets() { return assets; },
  // project a world point to video pixel coordinates (1920x1080) exactly as the renderer does
  project(v3, i) { applyCamera(i); const p = v3.clone().project(camera); return [(p.x * 0.5 + 0.5) * cam.width, (-p.y * 0.5 + 0.5) * cam.height, p.z]; } };
