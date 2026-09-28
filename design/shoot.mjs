// Captures the car page with headless Chrome over the DevTools protocol, in real time.
// Usage: node design/shoot.mjs <out.png> <url> <waitSeconds> [js to run before capture]
import { spawn } from 'node:child_process';
import { writeFileSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const [out, url, wait = '15', js = ''] = process.argv.slice(2);
const chrome = spawn('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', [
  '--headless=new', '--hide-scrollbars', '--remote-debugging-port=9333', '--window-size=1920,1200',
  `--user-data-dir=${mkdtempSync(join(tmpdir(), 'shoot-'))}`, 'about:blank',
], { stdio: 'ignore' });
const sleep = ms => new Promise(r => setTimeout(r, ms));

let target;
for (let i = 0; i < 50 && !target; i++) {
  await sleep(200);
  try { target = (await (await fetch('http://127.0.0.1:9333/json')).json()).find(t => t.type === 'page'); } catch {}
}
const ws = new WebSocket(target.webSocketDebuggerUrl);
await new Promise(r => ws.onopen = r);
let id = 0; const pending = new Map();
ws.onmessage = e => { const m = JSON.parse(e.data); pending.get(m.id)?.(m.result); };
const send = (method, params = {}) => new Promise(r => { pending.set(++id, r); ws.send(JSON.stringify({ id, method, params })); });

await send('Emulation.setDeviceMetricsOverride', { width: 1920, height: 1200, deviceScaleFactor: 1, mobile: false });
await send('Page.navigate', { url });
await sleep(Number(wait) * 1000);
if (js) { await send('Runtime.evaluate', { expression: js, awaitPromise: true }); await sleep(4000); }
const shot = await send('Page.captureScreenshot', { format: 'png' });
writeFileSync(out, Buffer.from(shot.data, 'base64'));
ws.close(); chrome.kill();
console.log('saved', out);
