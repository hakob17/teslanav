// Fake phone + car against the deployed relay: presence, control and binary forwarding.
const base = 'wss://teslanav-relay.hakob-hakobyan173.workers.dev/ws?room=TEST1234';
const open = role => new Promise((res, rej) => {
  const ws = new WebSocket(`${base}&role=${role}`); ws.binaryType = 'arraybuffer';
  ws.log = []; ws.onmessage = e => ws.log.push(typeof e.data === 'string' ? e.data : `bin:${e.data.byteLength}`);
  ws.onopen = () => res(ws); ws.onerror = rej;
});
const sleep = ms => new Promise(r => setTimeout(r, ms));
const phone = await open('phone'); await sleep(500);
const car = await open('car'); await sleep(800);
car.send(JSON.stringify({ type: 'want', format: 'h264' }));
const t0 = Date.now();
for (let i = 0; i < 30; i++) phone.send(new Uint8Array(40000));
phone.send(JSON.stringify({ type: 'config', codec: 'avc1.640028' }));
await sleep(2000);
console.log('phone got:', phone.log);
console.log('car got:', car.log.filter(x => !x.startsWith('bin')), 'binary frames:', car.log.filter(x => x.startsWith('bin')).length);
car.close(); await sleep(800); console.log('phone after car left:', phone.log.at(-1));
phone.close();
const bad = await fetch('https://teslanav-relay.hakob-hakobyan173.workers.dev/ws?room=bad&role=car'); console.log('bad room ->', bad.status);
process.exit(0);
