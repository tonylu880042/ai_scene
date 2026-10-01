import puppeteer from 'puppeteer-core'; import fs from 'fs';
const frames = [600, 1500, 3000, 5000, 6800];
const b = await puppeteer.launch({ executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: 'new', args: ['--autoplay-policy=no-user-gesture-required','--enable-unsafe-swiftshader'] });
const out = [];
for (const f of frames) {
  const p = await b.newPage(); await p.setViewport({ width: 960, height: 540 });
  await p.goto(`http://localhost:8765/player_web/index.html?debug=1&frame=${f}&autoplay=0&hud=0&pacers=5:30@8,5:45@16,6:15@26,6:30@40,6:00@60`);
  await new Promise(r => setTimeout(r, 5000));
  out.push(await p.evaluate(() => { const P = window.__player; const i = P.state.frame; return { frame: i,
    av: P.pacers.map(a => { const pos = a.av.root.position; const px = P.project(pos.clone(), i); return { name: a.spec.name, s: a.s, lane: a.laneNow, pos: [pos.x, pos.y, pos.z], px: px.slice(0, 2), ndcz: px[2], shown: a.shown }; }) }; }));
  await p.close();
}
fs.writeFileSync('foot.json', JSON.stringify(out, null, 1)); console.log('ok'); await b.close();
