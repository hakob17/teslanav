// HotspotNav relay: forwards the iPhone's screen stream to the car's browser.
//
//   wss://…/ws?room=<code>&role=phone   the broadcast extension (sends video)
//   wss://…/ws?room=<code>&role=car     the car page (receives video)
//
// One Durable Object per pairing code holds both ends. Binary messages go phone → cars;
// text messages (small JSON control messages) go both ways. Nothing is stored.

const ROOM = /^[A-Z0-9]{8}$/;

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === '/') return new Response('HotspotNav relay\n');
    if (url.pathname !== '/ws') return new Response('Not found', { status: 404 });

    const room = (url.searchParams.get('room') || '').toUpperCase();
    const role = url.searchParams.get('role');
    if (!ROOM.test(room) || (role !== 'phone' && role !== 'car')) {
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
    const role = new URL(request.url).searchParams.get('role');
    const { 0: client, 1: server } = new WebSocketPair();
    // Tags let us find each side again, even after the object wakes from hibernation.
    this.state.acceptWebSocket(server, [role]);

    if (role === 'phone') {
      // One phone per room: a reconnecting extension replaces the old socket.
      for (const old of this.state.getWebSockets('phone')) if (old !== server) old.close(1000, 'replaced');
      this.broadcast('car', { type: 'phone', online: true });
      server.send(JSON.stringify({ type: 'cars', count: this.state.getWebSockets('car').length }));
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
    } else if (typeof message === 'string') {
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

  gone(ws) {
    const [role] = this.state.getTags(ws);
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
