import puppeteer from 'puppeteer-core';
const url = process.argv[2];
const b = await puppeteer.launch({ executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: 'new',
  args: ['--autoplay-policy=no-user-gesture-required', '--window-size=1280,760', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist'] });
const p = await b.newPage(); await p.setViewport({ width: 1280, height: 720 });
p.on('console', m => console.log('console:', m.text())); p.on('pageerror', e => console.log('pageerror:', e.message));
await p.goto(url);
await new Promise(r => setTimeout(r, 8000));
const info = await p.evaluate(async () => {
  const P = window.__player, v = P.video;
  const s = () => ({ ct: v.currentTime, frame: P.state.frame, exp: Math.round(v.currentTime * 60), paused: v.paused, vis: document.visibilityState, gaps: P.pacers.map(x => +x.gap.toFixed(2)), rate: v.playbackRate });
  const a = s(); await new Promise(r => setTimeout(r, 2000)); const b = s();
  // rVFC rate
  let n = 0, t0 = performance.now(), mism = 0; await new Promise(res => { const f = (now, m) => { n++; if (performance.now() - t0 < 2000) v.requestVideoFrameCallback(f); else res(); }; v.requestVideoFrameCallback(f); });
  return { a, b, rvfcPerSec: n / 2 };
});
console.log(JSON.stringify(info));
await p.screenshot({ path: process.argv[3] || 'play.png' });
await b.close();
