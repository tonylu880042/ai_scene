import puppeteer from 'puppeteer-core';
const [url, name, wait] = [process.argv[2], process.argv[3], +(process.argv[4] || 5000)];
const b = await puppeteer.launch({ executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: 'new', args: ['--autoplay-policy=no-user-gesture-required','--enable-unsafe-swiftshader'] });
const p = await b.newPage(); await p.setViewport({ width: 1920, height: 1080 });
p.on('pageerror', e => console.log('pageerror:', e.message));
await p.goto(url); await new Promise(r => setTimeout(r, wait));
if (process.argv[5]) console.log(JSON.stringify(await p.evaluate(process.argv[5])));
await p.screenshot({ path: `/Users/tunghunglu/projects/ai_scene/player_web/verify/${name}.png` });
await b.close();
