// Captures the car page with headless Chrome over the DevTools protocol, following steps:
//   node design/shoot2.mjs out.png '[{"go":"url"},{"js":"..."},{"wait":5},{"go":"url"},{"wait":10},{"js":"..."}]'
// "go" navigates, "js" evaluates (awaiting promises), "wait" sleeps seconds. The page runs at
// 1920×1200, the Model 3/Y screen's CSS size.
import { spawn } from 'node:child_process';
import { writeFileSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const [out, stepsJson] = process.argv.slice(2);
const steps = JSON.parse(stepsJson);
const chrome = spawn('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', [
  '--headless=new', '--hide-scrollbars', '--remote-debugging-port=9334', '--window-size=1920,1200',
  '--use-angle=metal', '--enable-webgl', '--ignore-gpu-blocklist',
  `--user-data-dir=${mkdtempSync(join(tmpdir(), 'shoot-'))}`, 'about:blank',
], { stdio: 'ignore' });
const sleep = ms => new Promise(r => setTimeout(r, ms));

let target;
for (let i = 0; i < 50 && !target; i++) {
  await sleep(200);
  try { target = (await (await fetch('http://127.0.0.1:9334/json')).json()).find(t => t.type === 'page'); } catch {}
}
const ws = new WebSocket(target.webSocketDebuggerUrl);
await new Promise(r => ws.onopen = r);
let id = 0; const pending = new Map();
ws.onmessage = e => { const m = JSON.parse(e.data); pending.get(m.id)?.(m.result); };
const send = (method, params = {}) => new Promise(r => { pending.set(++id, r); ws.send(JSON.stringify({ id, method, params })); });

await send('Emulation.setDeviceMetricsOverride', { width: 1920, height: 1200, deviceScaleFactor: 1, mobile: false });
for (const step of steps) {
  if (step.go) await send('Page.navigate', { url: step.go });
  if (step.wait) await sleep(step.wait * 1000);
  if (step.js) {
    const r = await send('Runtime.evaluate', { expression: `(async () => { ${step.js} })()`, awaitPromise: true, returnByValue: true });
    if (r?.exceptionDetails) console.error('js error:', r.exceptionDetails.exception?.description || r.exceptionDetails.text);
    else if (r?.result?.value !== undefined) console.log('js:', JSON.stringify(r.result.value));
  }
}
const shot = await send('Page.captureScreenshot', { format: 'png' });
writeFileSync(out, Buffer.from(shot.data, 'base64'));
ws.close(); chrome.kill();
console.log('saved', out);
