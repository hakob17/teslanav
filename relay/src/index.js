// HotspotNav relay: forwards the iPhone's screen stream to the car's browser.
//
//   wss://…/ws?room=<code>&role=phone   the broadcast extension (sends video)
//   wss://…/ws?room=<code>&role=car     the car page in mirror mode (receives video)
//   wss://…/ws?room=<code>&role=nav     the car page in map mode (receives destinations only)
//   POST /send?room=<code>  {"type":"dest","lat":…,"lng":…,"name":…}
//                                       the phone's share extension: a place to drive to
//
// One Durable Object per pairing code holds both ends. Binary messages go phone → cars;
// text messages (small JSON control messages) go both ways. A destination sent while no car
// page is open is kept for 10 minutes and handed to the next one; nothing else is stored.

const ROOM = /^[A-Z0-9]{8}$/;

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === '/') return new Response('HotspotNav relay\n');
    const room = (url.searchParams.get('room') || '').toUpperCase();
    if (url.pathname === '/send') {
      if (request.method !== 'POST' || !ROOM.test(room)) return new Response('Bad request', { status: 400 });
      return env.ROOMS.get(env.ROOMS.idFromName(room)).fetch(request);
    }
    if (url.pathname !== '/ws') return new Response('Not found', { status: 404 });

    const role = url.searchParams.get('role');
    if (!ROOM.test(room) || !['phone', 'car', 'nav'].includes(role)) {
      return new Response('Bad room or role', { status: 400 });
    }
    if (request.headers.get('Upgrade') !== 'websocket') {
      return new Response('Expected a WebSocket', { status: 426 });
    }
    return env.ROOMS.get(env.ROOMS.idFromName(room)).fetch(request);
  },
};

export class Room {
  constructor(state) {
    this.state = state;
  }

  async fetch(request) {
    const url = new URL(request.url);
    if (url.pathname === '/send') return this.sendDestination(request);
    const role = url.searchParams.get('role');
    const { 0: client, 1: server } = new WebSocketPair();
    // Tags let us find each side again, even after the object wakes from hibernation.
    this.state.acceptWebSocket(server, [role]);

    if (role === 'phone') {
      // One phone per room: a reconnecting extension replaces the old socket.
      for (const old of this.state.getWebSockets('phone')) if (old !== server) old.close(1000, 'replaced');
      this.broadcast('car', { type: 'phone', online: true });
      server.send(JSON.stringify({ type: 'cars', count: this.state.getWebSockets('car').length }));
    } else if (role === 'nav') {
      // A destination shared before the car page was open: deliver it now, once.
      const pending = await this.state.storage.get('dest');
      if (pending && Date.now() - pending.at < 10 * 60_000) server.send(JSON.stringify(pending.message));
      if (pending) await this.state.storage.delete('dest');
    } else {
      const online = this.state.getWebSockets('phone').length > 0;
      server.send(JSON.stringify({ type: 'phone', online }));
      this.broadcast('phone', { type: 'cars', count: this.state.getWebSockets('car').length });
    }
    return new Response(null, { status: 101, webSocket: client });
  }

  webSocketMessage(ws, message) {
    const [role] = this.state.getTags(ws);
    if (role === 'phone') {
      // Video (binary) and control messages from the phone go to every car.
      for (const car of this.state.getWebSockets('car')) {
        try { car.send(message); } catch {}
      }
    } else if (role === 'car' && typeof message === 'string') {
      // Cars only ever send small control messages (format wanted, keyframe please).
      for (const phone of this.state.getWebSockets('phone')) {
        try { phone.send(message); } catch {}
      }
    }
  }

  webSocketClose(ws) {
    this.gone(ws);
  }

  webSocketError(ws) {
    this.gone(ws);
  }

  async sendDestination(request) {
    let body;
    try { body = await request.json(); } catch { return new Response('Bad JSON', { status: 400 }); }
    const lat = Number(body.lat), lng = Number(body.lng);
    if (!(Math.abs(lat) <= 90 && Math.abs(lng) <= 180)) return new Response('Bad coordinates', { status: 400 });
    const message = { type: 'dest', lat, lng, name: String(body.name || '').slice(0, 120), source: String(body.source || '').slice(0, 20) };
    const listeners = [...this.state.getWebSockets('nav'), ...this.state.getWebSockets('car')];
    for (const ws of listeners) {
      try { ws.send(JSON.stringify(message)); } catch {}
    }
    if (listeners.length) await this.state.storage.delete('dest');
    else await this.state.storage.put('dest', { message, at: Date.now() });
    return new Response(JSON.stringify({ delivered: listeners.length, queued: !listeners.length }), {
      headers: { 'Content-Type': 'application/json' },
    });
  }

  gone(ws) {
    const [role] = this.state.getTags(ws);
    if (role === 'nav') return;
    if (role === 'phone') {
      this.broadcast('car', { type: 'phone', online: false });
    } else {
      const count = this.state.getWebSockets('car').filter(c => c !== ws).length;
      this.broadcast('phone', { type: 'cars', count });
    }
  }

  broadcast(role, obj) {
    const text = JSON.stringify(obj);
    for (const ws of this.state.getWebSockets(role)) {
      try { ws.send(text); } catch {}
    }
  }
}
