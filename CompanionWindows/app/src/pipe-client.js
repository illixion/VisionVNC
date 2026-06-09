'use strict';
const net = require('net');
const { EventEmitter } = require('events');

const PIPE_PATH = '\\\\.\\pipe\\visionvnc-hotspot';
const RPC_TIMEOUT_MS = 20000;

/**
 * Newline-delimited JSON-RPC client over the backend's named pipe.
 * Auto-reconnects, surfaces server "event" notifications, and exposes rpc(method, params).
 *
 * Events: 'connected', 'disconnected', 'notify' (server push), 'rpc-error'.
 */
class HotspotClient extends EventEmitter {
  constructor() {
    super();
    this._sock = null;
    this._buf = '';
    this._nextId = 1;
    this._pending = new Map();
    this._connected = false;
    this._reconnectTimer = null;
    this._stopped = false;
  }

  get connected() {
    return this._connected;
  }

  start() {
    this._stopped = false;
    this._connect();
  }

  stop() {
    this._stopped = true;
    if (this._reconnectTimer) clearTimeout(this._reconnectTimer);
    if (this._sock) this._sock.destroy();
  }

  _connect() {
    if (this._stopped) return;
    const sock = net.connect(PIPE_PATH);
    this._sock = sock;
    sock.setEncoding('utf8');

    sock.on('connect', () => {
      this._connected = true;
      this._buf = '';
      this.emit('connected');
    });

    sock.on('data', (chunk) => this._onData(chunk));

    sock.on('error', () => {
      // Backend not up yet / pipe gone — handled by 'close' → reconnect.
    });

    sock.on('close', () => {
      const wasConnected = this._connected;
      this._connected = false;
      this._sock = null;
      // Reject any in-flight requests.
      for (const [, p] of this._pending) p.reject(new Error('pipe closed'));
      this._pending.clear();
      if (wasConnected) this.emit('disconnected');
      this._scheduleReconnect();
    });
  }

  _scheduleReconnect() {
    if (this._stopped) return;
    if (this._reconnectTimer) return;
    this._reconnectTimer = setTimeout(() => {
      this._reconnectTimer = null;
      this._connect();
    }, 1000);
  }

  _onData(chunk) {
    this._buf += chunk;
    let nl;
    while ((nl = this._buf.indexOf('\n')) >= 0) {
      const line = this._buf.slice(0, nl).trim();
      this._buf = this._buf.slice(nl + 1);
      if (!line) continue;
      let msg;
      try {
        msg = JSON.parse(line);
      } catch {
        continue;
      }
      if (msg.event) {
        this.emit('notify', msg.event, msg.data);
        continue;
      }
      const p = this._pending.get(msg.id);
      if (p) {
        this._pending.delete(msg.id);
        clearTimeout(p.timer);
        if (msg.error) p.reject(new Error(`${msg.error.code}: ${msg.error.message}`));
        else p.resolve(msg.result);
      }
    }
  }

  rpc(method, params) {
    return new Promise((resolve, reject) => {
      if (!this._connected || !this._sock) {
        reject(new Error('backend not connected'));
        return;
      }
      const id = this._nextId++;
      const req = { id, method };
      if (params !== undefined && params !== null) req.params = params;
      const timer = setTimeout(() => {
        this._pending.delete(id);
        reject(new Error(`RPC timeout: ${method}`));
      }, RPC_TIMEOUT_MS);
      this._pending.set(id, { resolve, reject, timer });
      try {
        this._sock.write(JSON.stringify(req) + '\n');
      } catch (e) {
        this._pending.delete(id);
        clearTimeout(timer);
        reject(e);
      }
    });
  }
}

module.exports = { HotspotClient, PIPE_PATH };
