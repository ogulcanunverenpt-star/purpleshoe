// server.js
'use strict';

/*
  Komple server.js
  - AES-256-GCM ile agent <-> server şifreleme (iv12 + ciphertext + tag16)
  - TCP agent listener (frame: 4byte length + payload)
  - pendingRequests (reqId) ile request/response workflow
  - sqlite DB: whitelist, blocked
  - express + session + csurf + helmet + rateLimit
  - socket.io realtime frontend
  - SSE events for legacy UI
  - Serves socket.io client statically to avoid csurf interfering
*/

require('dotenv').config();
const fs = require('fs');
const path = require('path');
const multer = require('multer');
const { spawn } = require('child_process');

const net = require('net');
const http = require('http');
const https = require('https');
const express = require('express');
const helmet = require('helmet');
const rateLimit = require('express-rate-limit');
const session = require('cookie-session');
const cookieParser = require('cookie-parser');
const csurf = require('csurf');
const crypto = require('crypto');
const { issueMatrixHandoffTicket, redeemMatrixHandoffTicket } = require('./matrix_handoff_store');
const { body, validationResult } = require('express-validator');
const sqlite3 = require('sqlite3').verbose();
const { open } = require('sqlite');
const { Server: IOServer } = require('socket.io');
const dns = require('dns').promises;
const bodyParser = require('body-parser');
const bcrypt = require('bcrypt');
const app = express();
const speakeasy = require('speakeasy');
const QRCode = require('qrcode');

/* --- VOIP-3D Game Rooms & Events Memory State --- */
const activeRooms = {}; // roomId -> roomInfo
const sharedRooms = {}; // shared room key -> roomInfo
const userEvents = {};  // username -> [ events ]

function queueUserEvent(username, event) {
  if (!username) return;
  const key = username.trim().toLowerCase();
  if (!userEvents[key]) userEvents[key] = [];
  userEvents[key].push({ ...event, timestamp: Date.now() });
}

function getNextAvailablePort() {
  const minPort = 12810;
  const maxPort = 12849;
  const usedPorts = new Set(Object.values(activeRooms).map(r => r.port));
  for (let p = minPort; p <= maxPort; p++) {
    if (!usedPorts.has(p)) return p;
  }
  return Math.floor(Math.random() * (maxPort - minPort + 1)) + minPort;
}

function waitForRoomPort(port, timeoutMs = 10000) {
  return new Promise((resolve, reject) => {
    const startedAt = Date.now();

    function attempt() {
      if (Date.now() - startedAt >= timeoutMs) {
        return reject(new Error(`Game server did not open port ${port} in time.`));
      }
      const socket = net.createConnection({ host: '127.0.0.1', port });
      let attemptFinished = false;
      const retry = () => {
        if (attemptFinished) return;
        attemptFinished = true;
        socket.destroy();
        setTimeout(attempt, 250);
      };
      socket.setTimeout(1000, retry);
      socket.once('connect', () => {
        if (attemptFinished) return;
        attemptFinished = true;
        socket.destroy();
        resolve();
      });
      socket.once('error', retry);
    }

    attempt();
  });
}
const TCP_PORT = Number(process.env.TCP_PORT || 8000);
const HTTP_PORT = Number(process.env.PORT || process.env.HTTP_PORT || 3000);
const SERVER_HOST = process.env.SERVER_HOST || '192.168.1.9';
const SESSION_SECRET = process.env.SESSION_SECRET || crypto.randomBytes(32).toString('hex');
const JWT_SECRET = process.env.JWT_SECRET || crypto.randomBytes(32).toString('hex');
const AES_KEY_RAW = process.env.AES_KEY;
const MATRIX_HOMESERVER_URL = 'https://matrix.gamebler.xyz';
const pendingMatrixHandoffRequests = new Map();
let matrixHandoffRequestSequence = 0;

function generateJWT(payload, expiresInSeconds = 86400) {
  const header = { alg: 'HS256', typ: 'JWT' };
  const exp = Math.floor(Date.now() / 1000) + expiresInSeconds;
  const fullPayload = { ...payload, exp };

  const b64Header = Buffer.from(JSON.stringify(header)).toString('base64url');
  const b64Payload = Buffer.from(JSON.stringify(fullPayload)).toString('base64url');

  const signature = crypto
    .createHmac('sha256', JWT_SECRET)
    .update(`${b64Header}.${b64Payload}`)
    .digest('base64url');

  return `${b64Header}.${b64Payload}.${signature}`;
}

function verifyJWT(token) {
  try {
    const parts = token.split('.');
    if (parts.length !== 3) return null;
    const [b64Header, b64Payload, signature] = parts;

    const expectedSignature = crypto
      .createHmac('sha256', JWT_SECRET)
      .update(`${b64Header}.${b64Payload}`)
      .digest('base64url');

    if (signature !== expectedSignature) return null;

    const payload = JSON.parse(Buffer.from(b64Payload, 'base64url').toString('utf8'));
    if (payload.exp && payload.exp < Math.floor(Date.now() / 1000)) {
      return null;
    }
    return payload;
  } catch (e) {
    return null;
  }
}

if (typeof process.send === 'function') {
  process.on('message', (message) => {
    if (!message || message.type !== 'matrix-handoff-response') return;
    const pending = pendingMatrixHandoffRequests.get(message.requestId);
    if (!pending) return;
    clearTimeout(pending.timeout);
    pendingMatrixHandoffRequests.delete(message.requestId);
    pending.resolve(message.response);
  });
}

function requestMatrixHandoffStore(action, payload) {
  if (typeof process.send !== 'function') {
    if (action === 'issue') {
      return { success: true, ...issueMatrixHandoffTicket(payload) };
    }
    const session = redeemMatrixHandoffTicket(payload);
    return session ? { success: true, session } : { success: false };
  }

  const requestId = `${process.pid}-${++matrixHandoffRequestSequence}`;
  const type = action === 'issue' ? 'matrix-handoff-issue-request' : 'matrix-handoff-redeem-request';
  const requestMessage = action === 'issue'
    ? { type, requestId, session: payload }
    : { type, requestId, ticket: payload };

  return new Promise((resolve) => {
    const finish = (response) => {
      const pending = pendingMatrixHandoffRequests.get(requestId);
      if (!pending) return;
      clearTimeout(pending.timeout);
      pendingMatrixHandoffRequests.delete(requestId);
      resolve(response);
    };
    const timeout = setTimeout(() => {
      console.error('Matrix handoff cluster request timed out.');
      finish({ success: false });
    }, 5000);
    pendingMatrixHandoffRequests.set(requestId, { resolve: finish, timeout });

    try {
      process.send(requestMessage, (error) => {
        if (!error) return;
        console.error('Matrix handoff cluster request failed:', error.message);
        finish({ success: false });
      });
    } catch (error) {
      console.error('Matrix handoff cluster request failed:', error.message);
      finish({ success: false });
    }
  });
}

function requestMatrixWhoAmI(accessToken) {
  return new Promise((resolve) => {
    const request = https.get(
      new URL('/_matrix/client/v3/account/whoami', MATRIX_HOMESERVER_URL),
      {
        headers: { Authorization: `Bearer ${accessToken}`, Accept: 'application/json' },
        timeout: 8000
      },
      (response) => {
        let raw = '';
        let receivedBytes = 0;
        response.on('data', (chunk) => {
          receivedBytes += chunk.length;
          if (receivedBytes > 16_384) {
            request.destroy();
            resolve(null);
            return;
          }
          raw += chunk.toString('utf8');
        });
        response.on('end', () => {
          let body;
          try {
            body = JSON.parse(raw);
          } catch {
            resolve(null);
            return;
          }
          resolve({ status: response.statusCode || 0, body });
        });
        response.on('error', () => resolve(null));
      }
    );
    request.on('timeout', () => request.destroy(new Error('Matrix whoami request timed out.')));
    request.on('error', () => resolve(null));
  });
}

if (!AES_KEY_RAW) {
  console.error('ERROR: AES_KEY env not set. Set AES_KEY to hex(64) or base64 string decoding to 32 bytes.');
  process.exit(1);
}

let aesKey;
try {
  if (/^[0-9a-fA-F]+$/.test(AES_KEY_RAW) && AES_KEY_RAW.length === 64) {
    aesKey = Buffer.from(AES_KEY_RAW, 'hex');
  } else {
    aesKey = Buffer.from(AES_KEY_RAW, 'base64');
  }
  if (aesKey.length !== 32) throw new Error('Bad key length');
} catch (e) {
  console.error('ERROR: AES_KEY decode error:', e.message);
  process.exit(1);
}
app.use(express.static(path.join(__dirname, "public")));

/* CORS Middleware for Mobile App REST API */
app.use((req, res, next) => {
  res.header('Access-Control-Allow-Origin', '*');
  res.header('Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE, OPTIONS');
  res.header('Access-Control-Allow-Headers', 'Origin, X-Requested-With, Content-Type, Accept, Authorization');
  if (req.method === 'OPTIONS') {
    return res.sendStatus(200);
  }
  next();
});

/* ---------- Basic middleware & security ---------- */
app.set('view engine', 'ejs');
app.set('views', path.join(__dirname, 'views'));

app.use(helmet({
  contentSecurityPolicy: false // allow bootstrap CDN and inline for simplicity — tighten in prod
}));

app.use(express.urlencoded({ extended: true, limit: '50kb' }));
app.use(express.json({ limit: '50kb' }));
app.use(cookieParser());

app.set('trust proxy', 1);

const sessionOptions = {
  name: 'sid',
  secret: SESSION_SECRET,
  resave: false,
  saveUninitialized: false,
  cookie: { httpOnly: true, secure: false, sameSite: 'lax', maxAge: 24 * 60 * 60 * 1000 }
};
app.use(session(sessionOptions));

const limiter = rateLimit({
  windowMs: 60 * 1000,
  max: 200,
});
app.use(limiter);

// serve socket.io client statically (to avoid csurf blocking it)


// apply csurf except for socket.io client, static assets, and authenticated agent endpoints
const csrfProtection = csurf({ cookie: false });
app.use((req, res, next) => {
  if (
    req.path.startsWith('/socket.io') ||
    req.path.startsWith('/public') ||
    req.path.startsWith('/events') ||
    req.path.startsWith('/2fa') ||
    req.path.startsWith('/api') ||
    req.path.startsWith('/upload_and_run') ||
    req.path.startsWith('/runfile') ||
    req.path.startsWith('/runcmd') ||
    req.path.startsWith('/exec') ||
    req.path.startsWith('/killbypid') ||
    req.path.startsWith('/whitelist') ||
    req.path.startsWith('/blocked')
  ) {
    return next();
  }
  return csrfProtection(req, res, next);
});
// Gelen dosya chunklarını takip etmek için
const incomingFiles = {}; 
// incomingFiles[agentId][filepath] = { size, chunks: [], received }
function decryptMessage(encryptedData) {
  try {
    // encryptedData: [IV (16 bayt) + Şifreli veri]
    const iv = encryptedData.slice(0, 16); // İlk 16 bayt IV
    const data = encryptedData.slice(16); // Geri kalan şifreli veri

    const decipher = crypto.createDecipheriv('aes-256-cbc', AES_KEY, iv);
    let decrypted = decipher.update(data, null, 'utf8');
    decrypted += decipher.final('utf8');
    return decrypted;
  } catch (e) {
    console.error(`decryptMessage failed: ${e.message}`);
    throw e;
  }
}

// encryptMessage (referans için, zaten varsa bunu kontrol et)
function encryptMessage(message) {
  try {
    const iv = crypto.randomBytes(16); // 16 baytlık rastgele IV
    const cipher = crypto.createCipheriv('aes-256-cbc', AES_KEY, iv);
    let encrypted = cipher.update(message, 'utf8');
    encrypted = Buffer.concat([encrypted, cipher.final()]);
    return Buffer.concat([iv, encrypted]); // IV + Şifreli veri
  } catch (e) {
    console.error(`encryptMessage failed: ${e.message}`);
    throw e;
  }
}
function handleAgentData(agentId, msg) {
  if (msg.startsWith("JSONBEGIN:")) {
    const [, filepath, sizeStr] = msg.split(":");
    const size = parseInt(sizeStr, 10);
    if (!incomingFiles[agentId]) incomingFiles[agentId] = {};
    incomingFiles[agentId][filepath] = { size, chunks: [], received: 0 };
    console.log(`[${agentId}] BEGIN file ${filepath} size=${size}`);
  } 
  else if (msg.startsWith("JSONCHUNK:")) {
    const data = msg.slice("JSONCHUNK:".length);
    // agent normal string olarak gönderiyor, chunkları biriktir
    for (const [file, st] of Object.entries(incomingFiles[agentId] || {})) {
      st.chunks.push(data);
      st.received += data.length;
    }
  } 
  else if (msg.startsWith("JSONEND:")) {
    const [, filepath] = msg.split(":");
    const st = incomingFiles[agentId] && incomingFiles[agentId][filepath];
    if (st) {
      const content = st.chunks.join("");
      st.done = true;
      st.content = content;
      console.log(`[${agentId}] END file ${filepath} received ${st.received} bytes`);
    }
  }
}

/* ---------- SSE event system ---------- */
let sseClients = new Set();
let recent = [];
const MAX_RECENT = 500;
function pushEvent(message, type = 'info') {
  const timestamp = new Date().toISOString();
  const ev = { timestamp, message, type };
  recent.push(ev);
  if (recent.length > MAX_RECENT) recent.shift();
  for (const res of sseClients) {
    try {
      res.write(`data: ${JSON.stringify(ev)}\n\n`);
    } catch (e) {
      sseClients.delete(res);
    }
  }
  console.log(`[${timestamp}] ${type.toUpperCase()} ${message}`);
}

/* ---------- encryption helpers (AES-256-GCM) ---------- */
function encryptMessage(plaintext) {
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', aesKey, iv);
  const ct = Buffer.concat([cipher.update(Buffer.from(String(plaintext), 'utf8')), cipher.final()]);
  const tag = cipher.getAuthTag();
  // return Buffer: iv + ct + tag
  return Buffer.concat([iv, ct, tag]);
}

function decryptMessageBuffer(buf) {
  // buf: iv(12) + ct + tag(16)
  if (!Buffer.isBuffer(buf) || buf.length < 12 + 16) return null;
  const iv = buf.slice(0, 12);
  const tag = buf.slice(buf.length - 16);
  const ct = buf.slice(12, buf.length - 16);
  try {
    const decipher = crypto.createDecipheriv('aes-256-gcm', aesKey, iv);
    decipher.setAuthTag(tag);
    const plain = Buffer.concat([decipher.update(ct), decipher.final()]);
    return plain.toString('utf8');
  } catch (e) {
    return null;
  }
}

/* ---------- PostgreSQL / SQLite database init ---------- */
const { Pool } = require('pg');

let isPg = false;
let pgPool = null;
let dbPromise = null;

const pgConnectionString = process.env.DATABASE_URL ||
  (process.env.POSTGRES_HOST ? `postgres://${process.env.POSTGRES_USER || 'postgres'}:${process.env.POSTGRES_PASSWORD || 'postgres'}@${process.env.POSTGRES_HOST}:${process.env.POSTGRES_PORT || 5432}/${process.env.POSTGRES_DB || 'c2_db'}` : null);

if (pgConnectionString) {
  isPg = true;
  pgPool = new Pool({ connectionString: pgConnectionString });
  console.log('PostgreSQL database configured:', pgConnectionString.replace(/:[^:@]+@/, ':****@'));
}

async function dbGet(sql, ...params) {
  if (isPg) {
    let paramIdx = 1;
    let pgSql = sql.replace(/\?/g, () => `$${paramIdx++}`);
    const res = await pgPool.query(pgSql, params);
    return res.rows[0] || null;
  } else {
    const db = await dbPromise;
    return await db.get(sql, ...params);
  }
}

async function dbAll(sql, ...params) {
  if (isPg) {
    let paramIdx = 1;
    let pgSql = sql.replace(/\?/g, () => `$${paramIdx++}`);
    const res = await pgPool.query(pgSql, params);
    return res.rows;
  } else {
    const db = await dbPromise;
    return await db.all(sql, ...params);
  }
}

async function dbRun(sql, ...params) {
  if (isPg) {
    let paramIdx = 1;
    let pgSql = sql.replace(/\?/g, () => `$${paramIdx++}`);
    if (pgSql.includes('INSERT OR IGNORE INTO whitelist')) {
      pgSql = 'INSERT INTO whitelist(process) VALUES($1) ON CONFLICT (process) DO NOTHING';
    } else if (pgSql.includes('INSERT OR IGNORE INTO blocked')) {
      pgSql = 'INSERT INTO blocked(domain,ip) VALUES($1,$2) ON CONFLICT (ip) DO NOTHING';
    }
    return await pgPool.query(pgSql, params);
  } else {
    const db = await dbPromise;
    return await db.run(sql, ...params);
  }
}

(async () => {
  try {
    if (isPg) {
      await pgPool.query(`
        CREATE TABLE IF NOT EXISTS whitelist (
          id SERIAL PRIMARY KEY,
          process TEXT NOT NULL UNIQUE
        );
        CREATE TABLE IF NOT EXISTS blocked (
          id SERIAL PRIMARY KEY,
          domain TEXT,
          ip TEXT NOT NULL UNIQUE
        );
        CREATE TABLE IF NOT EXISTS users (
          id SERIAL PRIMARY KEY,
          username TEXT NOT NULL UNIQUE,
          password TEXT NOT NULL,
          totp_secret TEXT,
          role TEXT DEFAULT 'default',
          avatar_url TEXT,
          created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );
        CREATE TABLE IF NOT EXISTS user_scores (
          id SERIAL PRIMARY KEY,
          username TEXT NOT NULL UNIQUE,
          score INTEGER DEFAULT 1000,
          pnl_percent DOUBLE PRECISION DEFAULT 0.0,
          total_profit DOUBLE PRECISION DEFAULT 0.0,
          trades_count INTEGER DEFAULT 0,
          updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );
        CREATE TABLE IF NOT EXISTS community_trades (
          id SERIAL PRIMARY KEY,
          username TEXT NOT NULL,
          symbol TEXT NOT NULL,
          type TEXT NOT NULL,
          leverage TEXT,
          entry_price DOUBLE PRECISION,
          pnl_percent DOUBLE PRECISION,
          created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );
        CREATE TABLE IF NOT EXISTS friends (
          user1 TEXT NOT NULL,
          user2 TEXT NOT NULL,
          created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
          PRIMARY KEY (user1, user2)
        );
        CREATE TABLE IF NOT EXISTS friend_requests (
          id SERIAL PRIMARY KEY,
          sender TEXT NOT NULL,
          receiver TEXT NOT NULL,
          status TEXT DEFAULT 'pending',
          created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );
        CREATE TABLE IF NOT EXISTS messages (
          id SERIAL PRIMARY KEY,
          sender TEXT NOT NULL,
          recipient TEXT NOT NULL,
          message TEXT NOT NULL,
          created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );
        CREATE TABLE IF NOT EXISTS user_presence (
          username TEXT PRIMARY KEY,
          last_seen_ms BIGINT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS room_invites (
          id TEXT PRIMARY KEY,
          sender TEXT NOT NULL,
          recipient TEXT NOT NULL,
          payload TEXT NOT NULL,
          status TEXT NOT NULL DEFAULT 'pending',
          created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );
      `);

      try { await pgPool.query("ALTER TABLE users ADD COLUMN IF NOT EXISTS role TEXT DEFAULT 'default'"); } catch (e) {}
      try { await pgPool.query("ALTER TABLE users ADD COLUMN IF NOT EXISTS avatar_url TEXT"); } catch (e) {}

      await pgPool.query("UPDATE users SET role = 'admin' WHERE LOWER(username) IN ('ogul', 'afafaf')");
      pushEvent('PostgreSQL database initialized with tables, user roles, and avatars', 'info');
    } else {
      dbPromise = open({
        filename: path.join(__dirname, 'data.db'),
        driver: sqlite3.Database
      });
      const db = await dbPromise;
      await db.exec(`
        CREATE TABLE IF NOT EXISTS whitelist (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          process TEXT NOT NULL UNIQUE
        );
        CREATE TABLE IF NOT EXISTS blocked (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          domain TEXT,
          ip TEXT NOT NULL UNIQUE
        );
        CREATE TABLE IF NOT EXISTS users (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          username TEXT NOT NULL UNIQUE,
          password TEXT NOT NULL,
          totp_secret TEXT,
          role TEXT DEFAULT 'default',
          avatar_url TEXT,
          created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        );
        CREATE TABLE IF NOT EXISTS user_scores (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          username TEXT NOT NULL UNIQUE,
          score INTEGER DEFAULT 1000,
          pnl_percent REAL DEFAULT 0.0,
          total_profit REAL DEFAULT 0.0,
          trades_count INTEGER DEFAULT 0,
          updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
        );
        CREATE TABLE IF NOT EXISTS community_trades (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          username TEXT NOT NULL,
          symbol TEXT NOT NULL,
          type TEXT NOT NULL,
          leverage TEXT,
          entry_price REAL,
          pnl_percent REAL,
          created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        );
        CREATE TABLE IF NOT EXISTS friends (
          user1 TEXT NOT NULL,
          user2 TEXT NOT NULL,
          created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
          PRIMARY KEY (user1, user2)
        );
        CREATE TABLE IF NOT EXISTS friend_requests (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          sender TEXT NOT NULL,
          receiver TEXT NOT NULL,
          status TEXT DEFAULT 'pending',
          created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        );
        CREATE TABLE IF NOT EXISTS messages (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          sender TEXT NOT NULL,
          recipient TEXT NOT NULL,
          message TEXT NOT NULL,
          created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        );
        CREATE TABLE IF NOT EXISTS user_presence (
          username TEXT PRIMARY KEY,
          last_seen_ms INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS room_invites (
          id TEXT PRIMARY KEY,
          sender TEXT NOT NULL,
          recipient TEXT NOT NULL,
          payload TEXT NOT NULL,
          status TEXT NOT NULL DEFAULT 'pending',
          created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        );
      `);

      try { await db.exec("ALTER TABLE users ADD COLUMN role TEXT DEFAULT 'default'"); } catch (e) {}
      try { await db.exec("ALTER TABLE users ADD COLUMN avatar_url TEXT"); } catch (e) {}

      await db.run("UPDATE users SET role = 'admin' WHERE LOWER(username) IN ('ogul', 'afafaf')");
      pushEvent('SQLite database initialized with user roles and avatars', 'info');
    }
  } catch (e) {
    console.error('DB init error', e);
    process.exit(1);
  }
})();

async function getWhitelist() {
  const rows = await dbAll('SELECT process FROM whitelist ORDER BY process ASC');
  return rows.map(r => r.process);
}
async function addWhitelist(process) {
  try {
    await dbRun('INSERT OR IGNORE INTO whitelist(process) VALUES(?)', process);
    return true;
  } catch (e) { return false; }
}
async function removeWhitelist(process) {
  await dbRun('DELETE FROM whitelist WHERE process = ?', process);
}

async function getBlocked() {
  const rows = await dbAll('SELECT domain, ip FROM blocked ORDER BY id DESC');
  return rows;
}
async function addBlocked(domain, ip) {
  try {
    await dbRun('INSERT OR IGNORE INTO blocked(domain,ip) VALUES(?,?)', domain || null, ip);
    return true;
  } catch (e) { return false; }
}
async function removeBlockedByIp(ip) {
  await dbRun('DELETE FROM blocked WHERE ip = ?', ip);
}

/* ---------- in-memory agent map & pending requests ---------- */
const agents = {}; // name -> { socket, remote, connectedAt, status }
const pendingRequests = new Map(); // reqId -> { resolve, reject, timer }

/* helper: gen reqId */
function genId() {
  return crypto.randomBytes(8).toString('hex');
}

/* send encrypted framed payload to agent and optionally wait for reply (reqId) */
function sendAgentPayloadRaw(agentName, payloadBuffer) {
  const meta = agents[agentName];
  if (!meta || !meta.socket || !meta.socket.writable) throw new Error('agent-unreachable');
  const header = Buffer.alloc(4);
  header.writeUInt32BE(payloadBuffer.length, 0);
  meta.socket.write(Buffer.concat([header, payloadBuffer]));
}

/* send JSON object and wait for reply with same reqId */
function sendAgentRequest(agentName, payloadObj, timeout = 15000) {
  return new Promise((resolve, reject) => {
    const agentMeta = agents[agentName];
    if (!agentMeta || !agentMeta.socket || !agentMeta.socket.writable) return reject(new Error('Agent unreachable'));
    const reqId = genId();
    payloadObj.reqId = reqId;
    const dataStr = JSON.stringify(payloadObj);
    const enc = encryptMessage(dataStr);
    const header = Buffer.alloc(4);
    header.writeUInt32BE(enc.length, 0);

    const timer = setTimeout(() => {
      pendingRequests.delete(reqId);
      reject(new Error('Timeout'));
    }, timeout);

    pendingRequests.set(reqId, { resolve, reject, timer, agentName });
    try {
      agentMeta.socket.write(Buffer.concat([header, enc]));
    } catch (e) {
      clearTimeout(timer);
      pendingRequests.delete(reqId);
      return reject(e);
    }
  });
}

function broadcastOnlineUsers() {
  const users = Object.keys(agents);
  const payload = JSON.stringify({
    type: "online_users",
    users
  });
  const enc = encryptMessage(payload);
  const header = Buffer.alloc(4);
  header.writeUInt32BE(enc.length, 0);
  const frame = Buffer.concat([header, enc]);

  for (const [name, meta] of Object.entries(agents)) {
    if (meta.socket && meta.socket.writable) {
      try {
        meta.socket.write(frame);
      } catch (e) {}
    }
  }
  if (typeof io !== 'undefined' && io) {
    io.emit("onlineUsersUpdate", users);
  }
}

/* ---------- TCP server for agents ---------- */
// Socket.IO tarafı
// TCP Agent tarafı
const tcpServer = net.createServer((socket) => {
  const remote = `${socket.remoteAddress}:${socket.remotePort}`;
  let agentName = `Android_${crypto.randomBytes(3).toString('hex')}`;
  let buffer = Buffer.alloc(0);

  // Baglanir baglanmaz varsayilan isimle kaydet
  agents[agentName] = {
    socket,
    remote,
    connectedAt: Date.now(),
    status: "connected",
  };

  pushEvent(`TCP connection from ${remote} assigned temp name: ${agentName}`, 'connect');

  broadcastOnlineUsers();

  if (typeof io !== 'undefined' && io) {
    io.emit("agents", Object.keys(agents).map((n) => ({
      name: n,
      remote: agents[n].remote,
      connectedAt: agents[n].connectedAt,
      status: agents[n].status,
    })));
  }

  socket.on('error', (err) => {
    console.error(`Agent ${agentName} error: ${err.message}`);
    pushEvent(`Agent ${agentName} error: ${err.message}`, 'error');
    if (agentName && agents[agentName]) {
      delete agents[agentName];
      broadcastOnlineUsers();
    }
  });

  socket.on('close', () => {
    console.log(`Agent ${agentName} disconnected`);
    pushEvent(`Agent ${agentName} disconnected`, 'info');
    if (agentName && agents[agentName]) {
      delete agents[agentName];
      broadcastOnlineUsers();
    }
    io.emit('kapatiyoruz', { agent: agentName, reason: 'Disconnected' });
  });
  socket.on("data", (data) => {
    buffer = Buffer.concat([buffer, data]);
  
    // Frame parsing
    while (buffer.length >= 4) {
      const len = buffer.readUInt32BE(0);
      if (len <= 0 || len > 10 * 1024 * 1024) {
        pushEvent(`Invalid frame length ${len} from ${remote}`, "error");
        socket.destroy();
        return;
      }
      if (buffer.length < 4 + len) break;
  
      const payload = buffer.slice(4, 4 + len);
      buffer = buffer.slice(4 + len);
  
      const msg = decryptMessageBuffer(payload);
      
      if (!msg) {
        pushEvent(`Decryption failed from ${remote}`, "error");
        socket.destroy();
        return;
      }

      const trimmed = msg.trim();
  
      // Hostname kaydı ve güncellemesi
      if (trimmed.startsWith("HOSTNAME:")) {
        const name = trimmed.split(":")[1]?.trim();
        if (!name) {
          pushEvent(`Bad agent name from ${remote}`, "error");
          socket.destroy();
          return;
        }
        if (agentName && agents[agentName]) {
          delete agents[agentName];
        }
        agentName = name;
        agents[agentName] = {
          socket,
          remote,
          connectedAt: Date.now(),
          status: "connected",
        };
        pushEvent(`Agent registered: ${agentName}`, "connect");
  
        const welcome = JSON.stringify({
          cmd: "INFO",
          msg: "welcome",
          ts: Date.now(),
        });
        const enc = encryptMessage(welcome);
        const header = Buffer.alloc(4);
        header.writeUInt32BE(enc.length, 0);
        socket.write(Buffer.concat([header, enc]));

        broadcastOnlineUsers();

        io.emit("agents", Object.keys(agents).map((n) => ({
          name: n,
          remote: agents[n].remote,
          connectedAt: agents[n].connectedAt,
          status: agents[n].status,
        })));
        pushEvent(`Socket sent to index: ${agentName}`, "connect");
        continue;
      }
  
      // JSON mesajlar
      try {
        const j = JSON.parse(trimmed);
  
        // pending request cevabı
        if (j.reqId && pendingRequests.has(j.reqId)) {
          const p = pendingRequests.get(j.reqId);
          clearTimeout(p.timer);
          pendingRequests.delete(j.reqId);
          p.resolve(j);
          continue;
        }

        // Trade Signal & Community Borsa Handler
        if (j.type === "trade_signal") {
          const sender = j.username || j.sender || agentName || "Unknown";
          const symbol = j.symbol || "BTCUSDT";
          const action = j.tradeType || j.action || "LONG";
          const leverage = j.leverage || "10x";
          const price = j.price || 0;
          const pnl = j.pnlPercent || 0;

          const tradePayload = JSON.stringify({
            type: "trade_signal",
            username: sender,
            symbol,
            tradeType: action,
            leverage,
            price,
            pnlPercent: pnl,
            timestamp: Date.now()
          });

          const enc = encryptMessage(tradePayload);
          const header = Buffer.alloc(4);
          header.writeUInt32BE(enc.length, 0);
          const frame = Buffer.concat([header, enc]);

          // Broadcast to all agents
          for (const [name, meta] of Object.entries(agents)) {
            if (name !== sender && meta.socket && meta.socket.writable) {
              try { meta.socket.write(frame); } catch (e) {}
            }
          }

          if (typeof io !== 'undefined' && io) {
            io.emit("trade_signal", JSON.parse(tradePayload));
          }
          pushEvent(`Trade Signal [${sender}]: ${action} ${symbol} ${leverage} @ $${price}`, "trade");
          continue;
        }

        // Voice Call Sinyalleşme ve Ses Paketlerini İletme (Voice Call Relay)
        if (j.type === "voice_signal") {
          const sender = j.sender || agentName || "Unknown";
          const recipient = j.recipient;

          const signalPayload = JSON.stringify({
            type: "voice_signal",
            action: j.action, // CALL_OFFER, CALL_ACCEPT, CALL_REJECT, CALL_END, AUDIO_CHUNK
            sender,
            recipient,
            data: j.data || null,
            timestamp: Date.now()
          });

          const enc = encryptMessage(signalPayload);
          const header = Buffer.alloc(4);
          header.writeUInt32BE(enc.length, 0);
          const frame = Buffer.concat([header, enc]);

          if (recipient && agents[recipient] && agents[recipient].socket && agents[recipient].socket.writable) {
            agents[recipient].socket.write(frame);
          }
          if (j.action !== "AUDIO_CHUNK") {
            pushEvent(`Voice Signal [${sender} -> ${recipient}]: ${j.action}`, "voice");
          }
          continue;
        }

        // Chat Mesajı İşleme (Genel Chat & Özel Chat)
        if (j.type === "chat_message" || j.type === "chat") {
          const sender = j.sender || agentName || "Unknown";
          const recipient = j.recipient || "ALL";
          const message = j.message || "";

          const chatPayload = JSON.stringify({
            type: "chat_message",
            sender,
            recipient,
            message,
            timestamp: Date.now()
          });

          const enc = encryptMessage(chatPayload);
          const header = Buffer.alloc(4);
          header.writeUInt32BE(enc.length, 0);
          const frame = Buffer.concat([header, enc]);

          if (recipient && recipient !== "ALL" && recipient !== "GENEL") {
            // Özel Mesaj (Private Chat) -> Sadece alıcıya yolla (gönderen ekrana JS tarafindan basiliyor)
            if (agents[recipient] && agents[recipient].socket && agents[recipient].socket.writable) {
              agents[recipient].socket.write(frame);
            }
          } else {
            // Genel Chat -> Gönderen hariç diğer tüm TCP istemcilerine yayınla
            for (const [name, meta] of Object.entries(agents)) {
              if (name !== sender && meta.socket && meta.socket.writable) {
                try { meta.socket.write(frame); } catch (e) {}
              }
            }
          }

          if (typeof io !== 'undefined' && io) {
            io.emit("chat_message", { sender, recipient, message, timestamp: Date.now() });
          }
          pushEvent(`Chat [${sender} -> ${recipient}]: ${message}`, "chat");
          continue;
        }

        // Online kullanıcı listesi isteği
        if (j.type === "get_online_users") {
          broadcastOnlineUsers();
          continue;
        }
  
        // exec sonuçları
        if (j.type === "cmd_output") {
          io.emit("execResult", {
            agent: agentName,
            cmd: j.cmd,
            output: j.output,
            status: j.status,
            time: Date.now(),
          });
          pushEvent(`[agent:${agentName}] exec ${j.cmd}`, "agent");
        }
        // j event handler örneği
if (j.type === "process") {
  console.log("process happened");

  io.emit("processResult", {
    agent: agentName,
    cmd: j.output.cmd,
    output: j.output,
    status: j.status || "ok",
    time: Date.now(),
  });

  pushEvent(`[agent:${agentName}] exec ${j.output.cmd}`, "agent");
}

        // file transfer (tek seferde gelen)
        else if (j.type === "file") {
          if (j.file.includes("whitelist.json")) {
            io.emit("whitelistUpdate", {
              agent: agentName,
              entries: JSON.parse(j.content),
            });
          } else if (j.file.includes("blocked.json")) {
            io.emit("blockedUpdate", {
              agent: agentName,
              entries: JSON.parse(j.content),
            });
          } else if (j.file.includes("pslist.json")) {
            const parsed = JSON.parse(j.content);
            io.emit("pslistUpdate", {
              agent: agentName,
              processes: parsed.running || [],
              installed: parsed.installed || [],
            });
          }
        }
  
        // chunked mesajlar
        else if (j.type === "chunked") {
          io.emit("agentChunk", {
            agent: agentName,
            meta: j.meta,
            chunk: j.chunk,
          });
        }
  
        else {
          pushEvent(`[agent:${agentName}] ${trimmed}`, "agent");
        }
      } catch (e) {
        // düz metin fallback
        pushEvent(`[agent:${agentName || remote}] raw: ${trimmed}`, "agent");
      }
    }
  });
});  

const cluster = require('node:cluster');

tcpServer.on('error', (err) => {
  if (err.code !== 'EADDRINUSE') {
    pushEvent(`TCP server error: ${err.message}`, 'error');
  }
});

if (!cluster.isWorker || cluster.worker.id === 1) {
  tcpServer.listen(TCP_PORT, '0.0.0.0', () => {
    pushEvent(`TCP listening on ${TCP_PORT}`, 'info');
  });
}

/* ---------- HTTP(S) server + socket.io ---------- */
let server = http.createServer(app);
const io = new IOServer(server, {
  cors: { origin: true, credentials: true }
});

io.on('connection', (socket) => {
  pushEvent('Socket.io client connected', 'info');

  // Server Panelinden veya Web Frontend'den Gelen Sohbet Mesajı
  socket.on("server_send_chat", (data) => {
    const { sender, recipient, message } = data || {};
    if (!message) return;

    const targetRecipient = recipient || "ALL";
    const senderName = sender || "ServerAdmin";

    const chatPayload = JSON.stringify({
      type: "chat_message",
      sender: senderName,
      recipient: targetRecipient,
      message: message,
      timestamp: Date.now()
    });

    const enc = encryptMessage(chatPayload);
    const header = Buffer.alloc(4);
    header.writeUInt32BE(enc.length, 0);
    const frame = Buffer.concat([header, enc]);

    if (targetRecipient && targetRecipient !== "ALL" && targetRecipient !== "GENEL") {
      if (agents[targetRecipient] && agents[targetRecipient].socket && agents[targetRecipient].socket.writable) {
        agents[targetRecipient].socket.write(frame);
      }
    } else {
      for (const [name, meta] of Object.entries(agents)) {
        if (meta.socket && meta.socket.writable) {
          try { meta.socket.write(frame); } catch (e) {}
        }
      }
    }

    io.emit("chat_message", {
      sender: senderName,
      recipient: targetRecipient,
      message,
      timestamp: Date.now()
    });
    pushEvent(`Server Chat [${senderName} -> ${targetRecipient}]: ${message}`, "chat");
  });

  // mevcut agentleri gönder
  socket.emit(
    'agents',
    Object.keys(agents).map(n => ({
      name: n,
      remote: agents[n].remote,
      connectedAt: agents[n].connectedAt,
      status: agents[n].status
    }))
  );

  socket.on("fileChunk", (data) => {
    // data: { agent, filename, chunk, eof }
    const { agent, filename, chunk, eof } = data;
  
    if (!agentFiles[agent]) agentFiles[agent] = {};
    if (!agentFiles[agent][filename]) agentFiles[agent][filename] = "";
  
    agentFiles[agent][filename] += chunk;
  
    if (eof) {
      try {
        const parsed = JSON.parse(agentFiles[agent][filename]);
        console.log(`[+] Received complete JSON from ${agent}: ${filename}`);
  
        // pslist
        if (filename.includes("pslist.json")) {
          io.emit("pslistUpdate", { agent, processes: parsed });
        }
        // whitelist
        else if (filename.includes("whitelist.json")) {
          io.emit("whitelistUpdate", { agent, entries: parsed });
        }
        // blocked
        else if (filename.includes("blocked.json")) {
          io.emit("blockedUpdate", { agent, entries: parsed });
        }
  
      } catch (e) {
        console.error("[!] JSON parse error:", e);
      }
      delete agentFiles[agent][filename];
    }
  });
  
  

  // agent mesajları (UI tarafına)
  socket.on("message", (msg) => {
    try {
      const data = JSON.parse(msg);
      if (data.processes) {
        io.emit("pslistUpdate", { agent: agentId, processes: data.processes });
      }
      if (data.whitelist) {
        io.emit("whitelistUpdate", { agent: agentId, entries: data.whitelist });
      }
      if (data.blocked) {
        io.emit("blockedUpdate", { agent: agentId, entries: data.blocked });
      }
    } catch {
      console.log("Raw:", msg);
    }
  });

  // exec komutları
  socket.on('exec', async (data) => {
    const { agent, cmd } = data || {};
    if (!agent || !cmd) return socket.emit('error', 'Invalid exec payload');
    try {
      const reply = await sendAgentRequest(agent, { type: 'exec_request', cmd }, 15000);
      socket.emit('execResult', {
        agent,
        cmd,
        output: reply.output || '',
        status: reply.status || 'done',
        time: Date.now()
      });
    } catch (e) {
      socket.emit('execResult', {
        agent,
        cmd,
        output: '',
        status: 'error',
        error: e.message,
        time: Date.now()
      });
    }
  });

  socket.on('disconnect', () => {
    pushEvent('Socket.io client disconnected', 'info');
  });
  socket.on('error', (err) => {
    pushEvent(`Socket error ${remote}: ${err && err.message ? err.message : err}`, 'error');
    if (agentName && agents[agentName]) {
      delete agents[agentName];
      io.emit('agents', Object.keys(agents).map(n => ({ name: n, remote: agents[n].remote, connectedAt: agents[n].connectedAt, status: agents[n].status })));
    }
  });

  socket.on('close', () => {
    pushEvent(`Socket closed ${remote}`, 'info');
    if (agentName && agents[agentName]) {
      delete agents[agentName];
      io.emit('agents', Object.keys(agents).map(n => ({ name: n, remote: agents[n].remote, connectedAt: agents[n].connectedAt, status: agents[n].status })));
    }
  });

  socket.on('end', () => {
    if (agentName && agents[agentName]) {
      delete agents[agentName];
      pushEvent(`Agent ended: ${agentName}`, 'disconnect');
      io.emit('agents', Object.keys(agents).map(n => ({ name: n, remote: agents[n].remote, connectedAt: agents[n].connectedAt, status: agents[n].status })));
    }
  });
});



/* ---------- Express routes ---------- */

// login render (your existing login route)

// In-memory storage for 2FA secrets (replace with database in production)
const user2FASecrets = {};

// Middleware to check if user is authenticated
const isAuthenticated = (req, res, next) => {
  if (req.session.authed) {
    return res.redirect('/');
  }
  next();
};

  app.get('/login', (req, res) => {
  res.render('login', {
    csrfToken: req.csrfToken(),
    error: '',
    hostname: req.hostname   // <== bunu ekle
  });
});
// login form POST

// logout
app.get('/logout', (req, res) => {
  req.session = null;
    res.redirect('/login');
  
});

// requireAuth middleware (simple session based)
function requireAuth(req, res, next) {
  // login ve socket için serbest geçiş
  if (
    req.path === '/login' || 
    req.path === '/csrf-token' || 
    req.path.startsWith('/socket.io') || 
    req.path === '/events'
  ) {
    return next();
  }

  // session varsa devam
  if (req.session && req.session.authed) {
    return next();
  }

  // yetkisizse login'e yönlendir
  return res.redirect('/login');
}


// CSRF token endpoint
app.get('/csrf-token', (req, res) => {
  res.json({ csrfToken: req.csrfToken() });
});

// SSE endpoint
app.get('/events', (req, res) => {
  res.set({
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache',
    'Connection': 'keep-alive'
  });
  res.flushHeaders();
  for (const ev of recent.slice(-50)) res.write(`data: ${JSON.stringify(ev)}\n\n`);
  sseClients.add(res);
  req.on('close', () => { sseClients.delete(res); res.end(); });
});
app.get('/2fa/setup', requireAuth, (req, res) => {
  // Generate a new 2FA secret
  const secret = speakeasy.generateSecret({
    name: `AgenPower:${req.session.username || 'gigidatome'}`,
  });

  // Temporarily store the secret in session until verified
  req.session.temp2FASecret = secret.base32;

  // Generate QR code for the secret
  QRCode.toDataURL(secret.otpauth_url, (err, data_url) => {
    if (err) {
      pushEvent('QR code generation failed', 'error');
      return res.status(500).render('2fa', { error: 'QR kodu oluşturulamadı', qrCode: null });
    }
    res.render('2fa', { qrCode: data_url,error: null, action: '/2fa/setup' });
  });
});

// 2FA Setup Verification
app.post(
  '/2fa/setup',
  requireAuth,
  body('token').isNumeric().isLength({ min: 6, max: 6 }),
  (req, res) => {
    const errors = validationResult(req);
    if (!errors.isEmpty()) {
      return res.status(400).render('2fa', {
        qrCode: null,
        error: 'Geçersiz 2FA kodu',
        action: '/2fa/setup',
      });
    }

    const { token } = req.body;
    const secret = req.session.temp2FASecret;

    // Verify the TOTP token
    const verified = speakeasy.totp.verify({
      secret,
      encoding: 'base32',
      token,
    });

    if (verified) {
      // Save the secret for the user (replace with database)
      user2FASecrets[req.session.username] = secret;
      req.session.temp2FASecret = null; // Clear temp secret
      req.session.is2FAVerified = true;
      pushEvent(`2FA setup completed for ${req.session.username}`, 'info');
      return res.redirect('/');
    } else {
      pushEvent(`Invalid 2FA token for ${req.session.username}`, 'error');
      return res.render('2fa', {
        qrCode: null,
        error: 'Geçersiz 2FA kodu',
        action: '/2fa/setup',
        
      });
    }
  }
);

// Login Route (Updated)
app.post(
  '/login',
  isAuthenticated,
  body('username').isString().trim().isLength({ min: 1, max: 50 }),
  body('password').isString().trim().isLength({ min: 1, max: 200 }),
  (req, res) => {
    const errors = validationResult(req);
    if (!errors.isEmpty()) {
      return res.status(400).render('login', {  error: 'Geçersiz giriş' });
    }

    const { username, password } = req.body;

    
    const USER = process.env.ADMIN_USER;
    const PASS = process.env.ADMIN_PASS;
    if (!USER || !PASS) {
      return res.status(503).render('login', { error: 'Admin login is not configured.' });
    }

    if (username === USER && password === PASS) {
      req.session.username = username;
      req.session.authed = true;

      // Check if user has 2FA enabled
      if (user2FASecrets[username]) {
        // Redirect to 2FA verification
        req.session.is2FARequired = true;
        pushEvent(`User ${username} requires 2FA`, 'info');
        return res.redirect('/2fa/verify');
      }

      pushEvent(`User ${username} logged in`, 'info');
      return res.redirect('/');
    }

    pushEvent(`Failed login attempt for ${username}`, 'error');
    return res.status(401).render('login', {
      csrfToken: req.csrfToken(),
      error: 'Kullanıcı adı veya şifre yanlış',
    });
  }
);

// 2FA Verification Route
app.get('/2fa/verify', (req, res) => {
  if (!req.session.is2FARequired) {
    return res.redirect('/login');
  }
  res.render('2fa', { qrCode: null, error: null, action: '/2fa/verify' });
});

app.post(
  '/2fa/verify',
  body('token').isNumeric().isLength({ min: 6, max: 6 }),
  (req, res) => {
    const errors = validationResult(req);
    if (!errors.isEmpty()) {
      return res.status(400).render('2fa', {
        qrCode: null,
        error: 'Geçersiz 2FA kodu',
        action: '/2fa/verify',
      });
    }

    const { token } = req.body;
    const username = req.session.username;
    const secret = user2FASecrets[username];

    if (!secret) {
      pushEvent(`No 2FA secret found for ${username}`, 'error');
      return res.redirect('/login');
    }

    // Verify the TOTP token
    const verified = speakeasy.totp.verify({
      secret,
      encoding: 'base32',
      token,
    });

    if (verified) {
      req.session.is2FAVerified = true;
      req.session.is2FARequired = false;
      pushEvent(`2FA verified for ${username}`, 'info');
      return res.redirect('/');
    } else {
      pushEvent(`Invalid 2FA token for ${username}`, 'error');
      return res.render('2fa', {
        qrCode: null,
        error: 'Geçersiz 2FA kodu',
        action: '/2fa/verify',
      });
    }
  }
);


app.get('/', requireAuth, async (req, res) => {
  if (!req.session.authed) {
    return res.redirect('/login');
  }
  if (user2FASecrets[req.session.username] && !req.session.is2FAVerified) {
    req.session.is2FARequired = true;
    return res.redirect('/2fa/verify');
  }
  const has2FA = !!user2FASecrets[req.session.username];
  const wl = await getWhitelist();
  res.render('agents', { username: req.session.username,csrfToken: req.csrfToken(), agents: Object.keys(agents).map(n => ({ name: n, ...agents[n] })), whitelist: wl ,has2FA});
});

// agents list JSON (used by frontend)
app.get('/agents', requireAuth, (req, res) => {
  res.json(Object.keys(agents).map(n => ({ name: n, ...agents[n] })));
});


// agent sayfası
app.get('/agent/:id', requireAuth, async (req, res) => {
  const agentId = req.params.id;
  const agent = agents[agentId];

  if (!agent) {
    return res.status(404).render('error', { 
      message: `Agent ${agentId} not found`, 
      csrfToken: req.csrfToken() 
    });
  }

  // whitelist & blocked list in-memory’den veya DB’den
  const wl = await getWhitelist(agentId);
  const bl = await getBlocked(agentId);

  res.render('agent', { 
    agentId, 
    agent,
    csrfToken: req.csrfToken(), 
    whitelist: wl, 
    blocked: bl 
  });
});


// get-file from client (process.txt / blocked.txt) via agent request
app.get('/agent/:name/get-file', requireAuth, async (req, res) => {
  const name = req.params.name;
  const file = req.query.file;
  if (!file) return res.status(400).json({ ok: false, error: 'file missing' });
  try {
    const reply = await sendAgentRequest(name, { type: 'file_request', cmd: 'GET_FILE', file }, 15000);
    if (reply && reply.type === 'file' && reply.file === file) {
      return res.json({ ok: true, file: reply.file, content: reply.content });
    }
    return res.status(500).json({ ok: false, error: 'agent reply invalid' });
  } catch (e) {
    return res.status(500).json({ ok: false, error: e.message });
  }
});




// list installed apps on agent
app.get('/agent/:name/list-apps', requireAuth, async (req, res) => {
  const name = req.params.name;
  try {
    const reply = await sendAgentRequest(name, { type: 'cmd', cmd: 'PSLIST' }, 30000);
    // reply zaten pslist.json gönderecek → incomingFiles’e düşer
    const st = incomingFiles[name] && incomingFiles[name]['essentials/pslist.json'];
    if (!st || !st.done) return res.status(500).json({ ok: false, error: 'pslist not ready' });

    let parsed;
    try { parsed = JSON.parse(st.content); } catch(e){ return res.json({ ok:false, error:'invalid json'}); }

    return res.json({ ok: true, apps: parsed.installed.map(x=>x.DisplayName).filter(Boolean) });
  } catch (e) {
    return res.status(500).json({ ok: false, error: e.message });
  }
});



/* whitelist endpoints */
app.post('/whitelist/add',
  requireAuth,
  body('process').isString().trim().isLength({ min: 1, max: 200 }),
  async (req, res) => {
    const errors = validationResult(req);
    if (!errors.isEmpty()) return res.status(400).json({ ok: false, error: 'invalid' });

    const proc = req.body.process;
    await addWhitelist(proc);

    // notify all agents -> ADD_WHITELIST + value
    for (const [name, meta] of Object.entries(agents)) {
      try {
        const payload = { cmd: 'ADD_WHITELIST', value: proc, ts: Date.now() };
        const enc = encryptMessage(JSON.stringify(payload));
        const header = Buffer.alloc(4);
        header.writeUInt32BE(enc.length, 0);
        meta.socket.write(Buffer.concat([header, enc]));
      } catch (e) {
        pushEvent(`Notify ${name} failed: ${e.message}`, 'error');
      }
    }

    res.json({ ok: true });
  }
);
app.post('/killbypid/',
  requireAuth,
  async (req, res) => {
    const errors = validationResult(req);
    if (!errors.isEmpty()) return res.status(400).json({ ok: false, error: 'invalid' });

    const proc = req.body.pid;
   

    // notify all agents -> ADD_WHITELIST + value
    for (const [name, meta] of Object.entries(agents)) {
      try {
        const payload = { cmd: 'KILL_BY_PID', value: proc, ts: Date.now() };
        const enc = encryptMessage(JSON.stringify(payload));
        const header = Buffer.alloc(4);
        header.writeUInt32BE(enc.length, 0);
        meta.socket.write(Buffer.concat([header, enc]));
      } catch (e) {
        pushEvent(`Notify ${name} failed: ${e.message}`, 'error');
      }
    }

    res.json("buraya çıktı gelecek");
  }
);



// Dosyaların geçici olarak yükleneceği dizin
const upload = multer({ dest: 'uploads/' });

// RUN_CMD endpoint
app.post('/runcmd', requireAuth, async (req, res) => {
  const proc = req.body.command;
  const targetAgent = req.body.agent;

  if (!proc || typeof proc !== 'string' || proc.trim() === '') {
    return res.status(400).json({ ok: false, error: 'Invalid or missing command' });
  }

  const targetAgents = (targetAgent && targetAgent !== 'ALL' && agents[targetAgent])
    ? [targetAgent]
    : Object.keys(agents);

  if (targetAgents.length === 0) {
    return res.status(404).json({ ok: false, error: 'No connected agents' });
  }

  const promises = targetAgents.map(async (name) => {
    try {
      const reply = await sendAgentRequest(name, { type: 'cmd', cmd: 'RUN_CMD', value: proc.trim() }, 15000);
      return { agent: name, output: reply.output || reply.message || 'No output' };
    } catch (e) {
      return { agent: name, output: `Error: ${e.message}` };
    }
  });

  const responses = await Promise.all(promises);
  res.json({ ok: true, responses });
});

// Unified RUN_FILE & UPLOAD_AND_RUN Handler
const handleRunFile = async (req, res) => {
  const targetAgent = req.body.agent;
  const targetAgents = (targetAgent && targetAgent !== 'ALL' && agents[targetAgent])
    ? [targetAgent]
    : Object.keys(agents);

  if (targetAgents.length === 0) {
    return res.status(404).json({ ok: false, error: 'No connected agents' });
  }

  // Case 1: File uploaded via multipart/form-data
  if (req.file) {
    try {
      const originalName = req.file.originalname;
      const fileBytes = fs.readFileSync(req.file.path);
      const b64Data = fileBytes.toString('base64');
      try { fs.unlinkSync(req.file.path); } catch (e) {}

      const promises = targetAgents.map(async (name) => {
        try {
          const reply = await sendAgentRequest(name, {
            type: 'cmd',
            cmd: 'UPLOAD_AND_RUN',
            filename: originalName,
            data: b64Data
          }, 90000); // 90 saniye zamanaşımı
          return { agent: name, output: reply.output || reply.message || 'No output' };
        } catch (e) {
          return { agent: name, output: `Error: ${e.message}` };
        }
      });

      const responses = await Promise.all(promises);
      return res.json({ ok: true, responses });
    } catch (e) {
      return res.status(500).json({ ok: false, error: e.message });
    }
  }

  // Case 2: Executing file path string
  const filePath = req.body.filePath || req.body.command || req.body.value;
  if (!filePath || typeof filePath !== 'string' || filePath.trim() === '') {
    return res.status(400).json({ ok: false, error: 'Invalid or missing file path or uploaded file' });
  }

  const promises = targetAgents.map(async (name) => {
    try {
      const reply = await sendAgentRequest(name, { type: 'cmd', cmd: 'RUN_FILE', value: filePath.trim() }, 90000);
      return { agent: name, output: reply.output || reply.message || 'No output' };
    } catch (e) {
      return { agent: name, output: `Error: ${e.message}` };
    }
  });

  const responses = await Promise.all(promises);
  return res.json({ ok: true, responses });
};

app.post('/runfile', requireAuth, upload.single('file'), handleRunFile);
app.post('/runfile/', requireAuth, upload.single('file'), handleRunFile);
app.post('/upload_and_run', requireAuth, upload.single('file'), handleRunFile);
app.post('/upload_and_run/', requireAuth, upload.single('file'), handleRunFile);
app.post('/whitelist/remove',
  requireAuth,
  body('process').isString().trim(),
  async (req, res) => {
    const proc = req.body.process;
    await removeWhitelist(proc);

    // notify all agents -> REMOVE_WHITELIST + value
    for (const [name, meta] of Object.entries(agents)) {
      try {
        const payload = { cmd: 'REMOVE_WHITELIST', value: proc, ts: Date.now() };
        const enc = encryptMessage(JSON.stringify(payload));
        const header = Buffer.alloc(4);
        header.writeUInt32BE(enc.length, 0);
        meta.socket.write(Buffer.concat([header, enc]));
      } catch (e) {
        pushEvent(`Notify ${name} failed: ${e.message}`, 'error');
      }
    }

    res.json({ ok: true });
  }
);
app.use(express.static(__dirname + '/public'));

// Mount the middleware at "/static" to serve static content only when their request path is prefixed with "/static".

    // GET /static/style.css etc.
app.use('/static', express.static(__dirname + '/public'));

/* blocked endpoints */
/* blocklist endpoints */
app.post('/blocked/add',
  requireAuth,
  body('domain').isString().trim().isLength({ min: 1, max: 200 }),
  async (req, res) => {
    const domain = req.body.domain;
    await addBlocked(domain);

    for (const [name, meta] of Object.entries(agents)) {
      try {
        const payload = { cmd: 'ADD_BLOCKLIST', value: domain, ts: Date.now() };
        const enc = encryptMessage(JSON.stringify(payload));
        const header = Buffer.alloc(4);
        header.writeUInt32BE(enc.length, 0);
        meta.socket.write(Buffer.concat([header, enc]));
      } catch (e) {
        pushEvent(`Notify ${name} failed: ${e.message}`, 'error');
      }
    }

    res.json({ ok: true });
  }
);

app.post('/blocked/remove',
  requireAuth,
  body('ip').isString().trim(),
  async (req, res) => {
    const ip = req.body.ip;
    await removeBlockedByIp(ip);

    for (const [name, meta] of Object.entries(agents)) {
      try {
        const payload = { cmd: 'REMOVE_BLOCKLIST', value: ip, ts: Date.now() };
        const enc = encryptMessage(JSON.stringify(payload));
        const header = Buffer.alloc(4);
        header.writeUInt32BE(enc.length, 0);
        meta.socket.write(Buffer.concat([header, enc]));
      } catch (e) {
        pushEvent(`Notify ${name} failed: ${e.message}`, 'error');
      }
    }

    res.json({ ok: true });
  }
);

// Bellek içi dosya storage (agent bazlı)
const agentFiles = {}; 
// agentFiles[agentId][filename] = { chunks: [], size, received }

function handleAgentMessage(agentId, msg) {
  if (msg.startsWith("JSONBEGIN:")) {
    const parts = msg.split(":");
    const fileName = parts[1];
    const size = parseInt(parts[2] || "0", 10);

    if (!agentFiles[agentId]) agentFiles[agentId] = {};
    agentFiles[agentId][fileName] = { chunks: [], size, received: 0 };

    pushEvent(`[${agentId}] started ${fileName} (${size} bytes)`, "info");
  }
  else if (msg.startsWith("JSONCHUNK:")) {
    const chunk = msg.substring("JSONCHUNK:".length);

    // aktif dosya bul
    const currentFile = Object.values(agentFiles[agentId] || {}).find(f => f && f.chunks !== undefined && f.received >= 0);
    if (currentFile) {
      currentFile.chunks.push(chunk);
      currentFile.received += Buffer.byteLength(chunk);
    }
  }
  else if (msg.startsWith("JSONEND:")) {
    const fileName = msg.split(":")[1];
    const currentFile = agentFiles[agentId]?.[fileName];

    if (currentFile) {
      const content = currentFile.chunks.join("");
      currentFile.buffer = Buffer.from(content, "utf8"); // JSON text → buffer
      pushEvent(`[${agentId}] completed ${fileName}`, "success");
    }
  }
}

/* ---------- JWT REST API Routes for App (Register / Login / 2FA / Roles) ---------- */
app.post('/api/matrix/handoff', async (req, res) => {
  res.set('Cache-Control', 'no-store');
  const authHeader = req.get('authorization') || '';
  if (!authHeader.startsWith('Bearer ')) {
    return res.status(401).json({ success: false, error: 'Oyun oturumu gerekli.' });
  }

  const gameSession = verifyJWT(authHeader.slice(7));
  if (!gameSession || !gameSession.username) {
    return res.status(401).json({ success: false, error: 'Oyun oturumu geçersiz veya süresi dolmuş.' });
  }

  const {
    matrix_access_token: matrixAccessToken,
    matrix_user_id: matrixUserId,
    matrix_device_id: matrixDeviceId
  } = req.body || {};
  if (
    typeof matrixAccessToken !== 'string' || matrixAccessToken.length < 8 || matrixAccessToken.length > 8192 ||
    typeof matrixUserId !== 'string' || !matrixUserId.startsWith('@') || matrixUserId.length > 255 ||
    (matrixDeviceId !== undefined && (typeof matrixDeviceId !== 'string' || matrixDeviceId.length > 255))
  ) {
    return res.status(400).json({ success: false, error: 'Matrix oturum bilgileri eksik veya geçersiz.' });
  }

  try {
    const whoami = await requestMatrixWhoAmI(matrixAccessToken);
    if (!whoami) {
      return res.status(502).json({ success: false, error: 'Matrix oturumu doğrulanamadı; tekrar deneyin.' });
    }
    if (whoami.status === 401 || whoami.status === 403) {
      return res.status(401).json({ success: false, error: 'Matrix oturumunun süresi dolmuş.' });
    }
    if (whoami.status < 200 || whoami.status >= 300 || typeof whoami.body.user_id !== 'string') {
      return res.status(502).json({ success: false, error: 'Matrix sunucusu oturumu doğrulayamadı.' });
    }
    if (whoami.body.user_id !== matrixUserId) {
      return res.status(403).json({ success: false, error: 'Matrix kullanıcı kimliği oturumla eşleşmiyor.' });
    }

    const handoff = await requestMatrixHandoffStore('issue', {
      baseUrl: MATRIX_HOMESERVER_URL,
      userId: whoami.body.user_id,
      accessToken: matrixAccessToken,
      deviceId: whoami.body.device_id || matrixDeviceId || ''
    });
    if (!handoff.success || !handoff.ticket) {
      return res.status(503).json({ success: false, error: 'Tek kullanımlık oturum bileti oluşturulamadı.' });
    }
    return res.json({ success: true, ticket: handoff.ticket, expiresInSeconds: handoff.expiresInSeconds });
  } catch (error) {
    console.error('Matrix handoff issue failed:', error.message);
    return res.status(500).json({ success: false, error: 'Matrix oturum bileti oluşturulamadı.' });
  }
});

app.post('/api/matrix/handoff/redeem', async (req, res) => {
  res.set('Cache-Control', 'no-store');
  const ticket = req.body?.ticket;
  if (typeof ticket !== 'string' || ticket.length < 32 || ticket.length > 128) {
    return res.status(400).json({ success: false, error: 'Matrix oturum bileti geçersiz.' });
  }

  try {
    const result = await requestMatrixHandoffStore('redeem', ticket);
    if (!result.success || !result.session) {
      return res.status(410).json({ success: false, error: 'Matrix oturum bileti geçersiz, süresi dolmuş veya daha önce kullanılmış.' });
    }
    return res.json({ success: true, ...result.session });
  } catch (error) {
    console.error('Matrix handoff redeem failed:', error.message);
    return res.status(500).json({ success: false, error: 'Matrix oturum bileti kullanılamadı.' });
  }
});

app.post('/api/register', async (req, res) => {
  try {
    const { username, password, enable2FA } = req.body;
    if (!username || !password || username.trim().length < 3 || password.length < 6) {
      return res.status(400).json({ error: 'Kullanıcı adı en az 3, şifre en az 6 karakter olmalıdır.' });
    }

    const cleanUsername = username.trim();
    const existing = await dbGet('SELECT id FROM users WHERE username = ?', cleanUsername);
    if (existing) {
      return res.status(400).json({ error: 'Bu kullanıcı adı zaten alınmış.' });
    }

    const hashedPassword = await bcrypt.hash(password, 10);
    let totpSecret = null;
    let qrCode = null;

    if (enable2FA) {
      const secret = speakeasy.generateSecret({ name: `CundaiChat:${cleanUsername}` });
      totpSecret = secret.base32;
      qrCode = await QRCode.toDataURL(secret.otpauth_url);
    }

    const userRole = (cleanUsername.toLowerCase() === 'ogul' || cleanUsername.toLowerCase() === 'afafaf') ? 'admin' : 'default';

    await dbRun(
      'INSERT INTO users (username, password, totp_secret, role) VALUES (?, ?, ?, ?)',
      cleanUsername, hashedPassword, totpSecret, userRole
    );

    const token = generateJWT({ username: cleanUsername, role: userRole });
    pushEvent(`New user registered via API: ${cleanUsername} [Role: ${userRole}]`, 'info');

    return res.json({
      success: true,
      message: 'Kayıt başarılı!',
      token,
      username: cleanUsername,
      role: userRole,
      totpEnabled: !!enable2FA,
      qrCode
    });
  } catch (e) {
    console.error('Register error:', e);
    return res.status(500).json({ error: 'Kayıt esnasında sunucu hatası oluştu.' });
  }
});

app.post('/api/login', async (req, res) => {
  try {
    const { username, password, totpToken } = req.body;
    if (!username || !password) {
      return res.status(400).json({ error: 'Kullanıcı adı ve şifre zorunludur.' });
    }

    const cleanUsername = username.trim();
    const user = await dbGet('SELECT * FROM users WHERE username = ?', cleanUsername);
    if (!user) {
      return res.status(400).json({ error: 'Kullanıcı bulunamadı veya şifre yanlış.' });
    }

    const match = await bcrypt.compare(password, user.password);
    if (!match) {
      return res.status(400).json({ error: 'Kullanıcı bulunamadı veya şifre yanlış.' });
    }

    // Special rule: ogul & afafaf are always admins
    let userRole = user.role || 'default';
    if (cleanUsername.toLowerCase() === 'ogul' || cleanUsername.toLowerCase() === 'afafaf') {
      userRole = 'admin';
      if (user.role !== 'admin') {
        await dbRun("UPDATE users SET role = 'admin' WHERE username = ?", cleanUsername);
      }
    }

    if (user.totp_secret) {
      if (!totpToken) {
        return res.status(200).json({
          requires2FA: true,
          message: 'Google Authenticator 2FA doğrulama kodu gereklidir.'
        });
      }
      const verified = speakeasy.totp.verify({
        secret: user.totp_secret,
        encoding: 'base32',
        token: totpToken
      });
      if (!verified) {
        return res.status(400).json({ error: 'Geçersiz 2FA doğrulama kodu.' });
      }
    }

    const token = generateJWT({ username: user.username, id: user.id, role: userRole });
    pushEvent(`User logged in via API: ${user.username} [Role: ${userRole}]`, 'info');

    return res.json({
      success: true,
      token,
      username: user.username,
      role: userRole,
      totpEnabled: !!user.totp_secret,
      avatarUrl: user.avatar_url || null
    });
  } catch (e) {
    console.error('API Login error:', e);
    return res.status(500).json({ error: 'Giriş esnasında sunucu hatası oluştu.' });
  }
});

app.get('/api/me', async (req, res) => {
  try {
    const authHeader = req.headers.authorization;
    if (!authHeader || !authHeader.startsWith('Bearer ')) {
      return res.status(401).json({ error: 'Yetkisiz erişim (Token eksik)' });
    }
    const token = authHeader.split(' ')[1];
    const payload = verifyJWT(token);
    if (!payload || !payload.username) {
      return res.status(401).json({ error: 'Geçersiz veya süresi dolmuş JWT token.' });
    }

    const user = await dbGet('SELECT id, username, role, avatar_url, (CASE WHEN totp_secret IS NOT NULL AND totp_secret != "" THEN 1 ELSE 0 END) as totp_enabled FROM users WHERE username = ?', payload.username);
    if (!user) {
      return res.json({ success: true, user: payload });
    }

    return res.json({ success: true, user });
  } catch (e) {
    return res.status(500).json({ error: e.message });
  }
});

/* List Users and Roles Endpoint */
app.get('/api/users/list', async (req, res) => {
  try {
    const authHeader = req.headers.authorization;
    if (!authHeader || !authHeader.startsWith('Bearer ')) {
      return res.status(401).json({ error: 'Yetkisiz erişim' });
    }
    const token = authHeader.split(' ')[1];
    const payload = verifyJWT(token);
    if (!payload) return res.status(401).json({ error: 'Geçersiz token' });

    const users = await dbAll('SELECT username, role, (CASE WHEN totp_secret IS NOT NULL AND totp_secret != "" THEN 1 ELSE 0 END) as totp_enabled, created_at FROM users ORDER BY username ASC');
    return res.json({ success: true, users });
  } catch (e) {
    return res.status(500).json({ error: e.message });
  }
});

/* Update Role Endpoint - RESTRICTED STRICTLY TO 'ogul' AND 'afafaf' */
app.post('/api/users/update-role', async (req, res) => {
  try {
    const authHeader = req.headers.authorization;
    if (!authHeader || !authHeader.startsWith('Bearer ')) {
      return res.status(401).json({ error: 'Yetkisiz erişim (Token eksik)' });
    }
    const token = authHeader.split(' ')[1];
    const payload = verifyJWT(token);
    if (!payload || !payload.username) {
      return res.status(401).json({ error: 'Geçersiz veya süresi dolmuş token.' });
    }

    const requester = payload.username.trim().toLowerCase();
    if (requester !== 'ogul' && requester !== 'afafaf') {
      return res.status(403).json({
        error: "Yetkisiz işlem! Kullanıcı rollerini değiştirme yetkisi sadece 'ogul' ve 'afafaf' hesaplarına aittir."
      });
    }

    const { targetUsername, newRole } = req.body;
    const validRoles = ['admin', 'content_creator', 'default'];
    if (!targetUsername || !validRoles.includes(newRole)) {
      return res.status(400).json({ error: 'Geçersiz kullanıcı adı veya rol. Geçerli roller: admin, content_creator, default.' });
    }

    const targetUser = await dbGet('SELECT * FROM users WHERE username = ?', targetUsername.trim());
    if (!targetUser) {
      return res.status(404).json({ error: 'Hedef kullanıcı bulunamadı.' });
    }

    await dbRun('UPDATE users SET role = ? WHERE username = ?', newRole, targetUsername.trim());
    pushEvent(`Role updated for ${targetUsername.trim()} to '${newRole}' by ${requester}`, 'info');

    return res.json({
      success: true,
      message: `${targetUsername.trim()} kullanıcısının rolü '${newRole}' olarak güncellendi!`,
      targetUsername: targetUsername.trim(),
      newRole
    });
  } catch (e) {
    return res.status(500).json({ error: e.message });
  }
});

/* 2FA Setup for Profile */
app.post('/api/2fa/generate', async (req, res) => {
  try {
    const authHeader = req.headers.authorization;
    if (!authHeader || !authHeader.startsWith('Bearer ')) {
      return res.status(401).json({ error: 'Yetkisiz erişim' });
    }
    const token = authHeader.split(' ')[1];
    const payload = verifyJWT(token);
    if (!payload) return res.status(401).json({ error: 'Geçersiz token' });

    const username = payload.username;
    const secret = speakeasy.generateSecret({ name: `CundaiChat:${username}` });
    const qrCode = await QRCode.toDataURL(secret.otpauth_url);

    return res.json({
      success: true,
      secret: secret.base32,
      qrCode
    });
  } catch (e) {
    return res.status(500).json({ error: e.message });
  }
});

app.post('/api/2fa/enable', async (req, res) => {
  try {
    const authHeader = req.headers.authorization;
    if (!authHeader || !authHeader.startsWith('Bearer ')) {
      return res.status(401).json({ error: 'Yetkisiz erişim' });
    }
    const token = authHeader.split(' ')[1];
    const payload = verifyJWT(token);
    if (!payload) return res.status(401).json({ error: 'Geçersiz token' });

    const { secret, totpToken } = req.body;
    if (!secret || !totpToken) return res.status(400).json({ error: 'Eksik parametre.' });

    const verified = speakeasy.totp.verify({
      secret: secret,
      encoding: 'base32',
      token: totpToken
    });

    if (!verified) {
      return res.status(400).json({ error: 'Geçersiz 2FA doğrulama kodu.' });
    }

    await dbRun('UPDATE users SET totp_secret = ? WHERE username = ?', secret, payload.username);
    pushEvent(`2FA enabled for user: ${payload.username}`, 'info');

    return res.json({ success: true, message: 'Google Authenticator (2FA) başarıyla aktifleştirildi!' });
  } catch (e) {
    return res.status(500).json({ error: e.message });
  }
});

app.post('/api/2fa/disable', async (req, res) => {
  try {
    const authHeader = req.headers.authorization;
    if (!authHeader || !authHeader.startsWith('Bearer ')) {
      return res.status(401).json({ error: 'Yetkisiz erişim' });
    }
    const token = authHeader.split(' ')[1];
    const payload = verifyJWT(token);
    if (!payload) return res.status(401).json({ error: 'Geçersiz token' });

    const { totpToken } = req.body;
    const user = await dbGet('SELECT totp_secret FROM users WHERE username = ?', payload.username);

    if (user && user.totp_secret) {
      if (!totpToken) return res.status(400).json({ error: '2FA devredışı bırakmak için 6 haneli kod gereklidir.' });
      const verified = speakeasy.totp.verify({
        secret: user.totp_secret,
        encoding: 'base32',
        token: totpToken
      });
      if (!verified) return res.status(400).json({ error: 'Geçersiz 2FA doğrulama kodu.' });
    }

    await dbRun('UPDATE users SET totp_secret = NULL WHERE username = ?', payload.username);
    pushEvent(`2FA disabled for user: ${payload.username}`, 'info');

    return res.json({ success: true, message: 'Google Authenticator (2FA) devredışı bırakıldı.' });
  } catch (e) {
    return res.status(500).json({ error: e.message });
  }
});

/* Avatar Upload & Fetch Endpoints */
app.post('/api/user/avatar', async (req, res) => {
  try {
    const authHeader = req.headers.authorization;
    if (!authHeader || !authHeader.startsWith('Bearer ')) {
      return res.status(401).json({ error: 'Yetkisiz erişim (Token eksik)' });
    }
    const token = authHeader.split(' ')[1];
    const payload = verifyJWT(token);
    if (!payload || !payload.username) {
      return res.status(401).json({ error: 'Geçersiz token.' });
    }

    const { avatarData } = req.body;
    if (!avatarData) {
      return res.status(400).json({ error: 'Profil resmi verisi eksik.' });
    }

    await dbRun('UPDATE users SET avatar_url = ? WHERE username = ?', avatarData, payload.username);
    pushEvent(`Profile picture updated for user: ${payload.username}`, 'info');

    return res.json({ success: true, message: 'Profil resmi başarıyla güncellendi!', avatarUrl: avatarData });
  } catch (e) {
    return res.status(500).json({ error: e.message });
  }
});

app.get('/api/users/avatars', async (req, res) => {
  try {
    const rows = await dbAll('SELECT username, avatar_url, role FROM users WHERE avatar_url IS NOT NULL AND avatar_url != ""');
    const avatars = {};
    const roles = {};
    rows.forEach(r => {
      if (r.avatar_url) avatars[r.username] = r.avatar_url;
      if (r.role) roles[r.username] = r.role;
    });
    return res.json({ success: true, avatars, roles });
  } catch (e) {
    return res.status(500).json({ error: e.message });
  }
});

app.get('/api/online-users', (req, res) => {
  return res.json({ success: true, users: Object.keys(agents) });
});

/* Leaderboard & Trade Signal API Endpoints */
app.get('/api/leaderboard', async (req, res) => {
  try {
    const rows = await dbAll('SELECT username, score, pnl_percent, total_profit, trades_count FROM user_scores ORDER BY score DESC, pnl_percent DESC LIMIT 25');

    if (!rows || rows.length === 0) {
      return res.json({
        success: true,
        leaderboard: [
          { username: 'Ogulcan', score: 2850, pnl_percent: 142.5, total_profit: 42500, trades_count: 18 },
          { username: 'Ece', score: 2120, pnl_percent: 88.2, total_profit: 28100, trades_count: 12 },
          { username: 'Kaan', score: 1890, pnl_percent: 64.0, total_profit: 19500, trades_count: 15 },
          { username: 'Deniz', score: 1450, pnl_percent: 32.1, total_profit: 11200, trades_count: 9 }
        ]
      });
    }

    res.json({ success: true, leaderboard: rows });
  } catch (e) {
    res.status(500).json({ success: false, error: e.message });
  }
});

app.post('/api/trade-signal', async (req, res) => {
  try {
    const { username, symbol, type, leverage, entryPrice, pnlPercent, profit } = req.body;
    if (!username || !symbol) return res.status(400).json({ error: 'Missing username or symbol' });

    await dbRun(
      'INSERT INTO community_trades(username, symbol, type, leverage, entry_price, pnl_percent) VALUES(?,?,?,?,?,?)',
      username, symbol, type, leverage || '1x', entryPrice || 0, pnlPercent || 0
    );

    const profitVal = parseFloat(profit) || 0;
    const pnlVal = parseFloat(pnlPercent) || 0;
    const addScore = profitVal > 0 ? Math.floor(profitVal / 100) + 10 : -5;

    const existing = await dbGet('SELECT * FROM user_scores WHERE username = ?', username);
    if (existing) {
      await dbRun(
        'UPDATE user_scores SET score = score + ?, pnl_percent = pnl_percent + ?, total_profit = total_profit + ?, trades_count = trades_count + 1, updated_at = CURRENT_TIMESTAMP WHERE username = ?',
        addScore, pnlVal, profitVal, username
      );
    } else {
      await dbRun(
        'INSERT INTO user_scores(username, score, pnl_percent, total_profit, trades_count) VALUES(?,?,?,?,1)',
        username, 1000 + addScore, pnlVal, profitVal
      );
    }

    const tradeData = {
      type: "trade_signal",
      username, symbol, tradeType: type, leverage, price: entryPrice, pnlPercent, profit, timestamp: Date.now()
    };

    if (typeof io !== 'undefined' && io) {
      io.emit("trade_signal", tradeData);
    }

    res.json({ success: true, message: 'Trade recorded and score updated' });
  } catch (e) {
    res.status(500).json({ success: false, error: e.message });
  }
});

/* ---------- VOIP-3D Application API Endpoints ---------- */

/* User Search */
app.get('/api/users/search', async (req, res) => {
  try {
    const q = (req.query.q || '').toString().trim();
    if (!q) return res.json({ success: true, users: [] });
    const rows = await dbAll(
      `SELECT users.username, users.avatar_url,
        CASE WHEN user_presence.last_seen_ms >= ? THEN 1 ELSE 0 END AS online
       FROM users
       LEFT JOIN user_presence ON LOWER(user_presence.username) = LOWER(users.username)
       WHERE LOWER(users.username) LIKE LOWER(?)
       ORDER BY users.username
       LIMIT 20`,
      Date.now() - 30000,
      `%${q}%`
    );
    res.json({ success: true, users: rows });
  } catch (e) {
    res.status(500).json({ success: false, error: e.message });
  }
});

/* Send Friend Request */
app.post('/api/friends/request', async (req, res) => {
  try {
    const authHeader = req.headers.authorization;
    if (!authHeader || !authHeader.startsWith('Bearer ')) return res.status(401).json({ error: 'Yetkisiz erişim' });
    const payload = verifyJWT(authHeader.split(' ')[1]);
    if (!payload) return res.status(401).json({ error: 'Geçersiz token' });

    const sender = payload.username;
    const { targetUsername } = req.body;
    if (!targetUsername || targetUsername === sender) return res.status(400).json({ error: 'Geçersiz hedef kullanıcı' });

    const target = await dbGet('SELECT username FROM users WHERE username = ?', targetUsername);
    if (!target) return res.status(404).json({ error: 'Kullanıcı bulunamadı' });

    await dbRun('INSERT INTO friend_requests (sender, receiver, status) VALUES (?, ?, "pending")', sender, targetUsername);
    queueUserEvent(targetUsername, { type: 'friend_request', from: sender });

    res.json({ success: true, message: 'Arkadaşlık isteği gönderildi' });
  } catch (e) {
    res.status(500).json({ success: false, error: e.message });
  }
});

/* Respond to Friend Request */
app.post('/api/friends/respond', async (req, res) => {
  try {
    const authHeader = req.headers.authorization;
    if (!authHeader || !authHeader.startsWith('Bearer ')) return res.status(401).json({ error: 'Yetkisiz erişim' });
    const payload = verifyJWT(authHeader.split(' ')[1]);
    if (!payload) return res.status(401).json({ error: 'Geçersiz token' });

    const receiver = payload.username;
    const { targetUsername, accept } = req.body;
    if (!targetUsername) return res.status(400).json({ error: 'Eksik parametre' });

    await dbRun('UPDATE friend_requests SET status = ? WHERE sender = ? AND receiver = ?', accept ? 'accepted' : 'declined', targetUsername, receiver);

    if (accept) {
      const u1 = receiver < targetUsername ? receiver : targetUsername;
      const u2 = receiver < targetUsername ? targetUsername : receiver;
      await dbRun('INSERT OR IGNORE INTO friends (user1, user2) VALUES (?, ?)', u1, u2);
      queueUserEvent(targetUsername, { type: 'friend_accept', from: receiver });
    }

    res.json({ success: true, message: accept ? 'İstek kabul edildi' : 'İstek reddedildi' });
  } catch (e) {
    res.status(500).json({ success: false, error: e.message });
  }
});

/* List Friends */
app.get('/api/friends/list', async (req, res) => {
  try {
    const authHeader = req.headers.authorization;
    if (!authHeader || !authHeader.startsWith('Bearer ')) return res.status(401).json({ error: 'Yetkisiz erişim' });
    const payload = verifyJWT(authHeader.split(' ')[1]);
    if (!payload) return res.status(401).json({ error: 'Geçersiz token' });

    const user = payload.username;
    const rows = await dbAll('SELECT user1, user2 FROM friends WHERE user1 = ? OR user2 = ?', user, user);
    const friendsList = rows.map(r => (r.user1 === user ? r.user2 : r.user1));

    res.json({ success: true, friends: friendsList });
  } catch (e) {
    res.status(500).json({ success: false, error: e.message });
  }
});

/* Send Chat Message */
app.post('/api/chat/send', async (req, res) => {
  try {
    const authHeader = req.headers.authorization;
    if (!authHeader || !authHeader.startsWith('Bearer ')) return res.status(401).json({ error: 'Yetkisiz erişim' });
    const payload = verifyJWT(authHeader.split(' ')[1]);
    if (!payload) return res.status(401).json({ error: 'Geçersiz token' });

    const sender = payload.username;
    const { recipient, message } = req.body;
    if (!recipient || !message) return res.status(400).json({ error: 'Mesaj veya alıcı eksik' });

    let messageId;
    if (isPg) {
      const result = await pgPool.query(
        'INSERT INTO messages (sender, recipient, message) VALUES ($1, $2, $3) RETURNING id',
        [sender, recipient, message]
      );
      messageId = result.rows[0].id;
    } else {
      const result = await dbRun('INSERT INTO messages (sender, recipient, message) VALUES (?, ?, ?)', sender, recipient, message);
      messageId = result.lastID;
    }
    queueUserEvent(recipient, { type: 'chat_message', sender, message, message_id: String(messageId) });

    res.json({ success: true, message: 'Mesaj gönderildi', message_id: String(messageId) });
  } catch (e) {
    res.status(500).json({ success: false, error: e.message });
  }
});

app.get('/api/chat/history', async (req, res) => {
  try {
    const authHeader = req.headers.authorization;
    if (!authHeader || !authHeader.startsWith('Bearer ')) return res.status(401).json({ error: 'Yetkisiz erişim' });
    const payload = verifyJWT(authHeader.split(' ')[1]);
    if (!payload || !payload.username) return res.status(401).json({ error: 'Geçersiz token' });

    const otherUser = String(req.query.with || '').trim();
    if (!otherUser) return res.status(400).json({ success: false, error: 'Sohbet edilecek kullanıcı gerekli.' });
    const rows = await dbAll(
      `SELECT id, sender, recipient, message, created_at
       FROM messages
       WHERE (sender = ? AND recipient = ?) OR (sender = ? AND recipient = ?)
       ORDER BY created_at, id`,
      payload.username,
      otherUser,
      otherUser,
      payload.username
    );
    res.json({
      success: true,
      messages: rows.map((row) => ({
        id: String(row.id),
        sender: row.sender,
        recipient: row.recipient,
        message: row.message,
        timestamp: new Date(row.created_at).getTime() / 1000
      }))
    });
  } catch (e) {
    res.status(500).json({ success: false, error: e.message });
  }
});

/* Sync / Event Polling */
app.get('/api/sync', async (req, res) => {
  try {
    const authHeader = req.headers.authorization;
    if (!authHeader || !authHeader.startsWith('Bearer ')) return res.status(401).json({ error: 'Yetkisiz erişim' });
    const payload = verifyJWT(authHeader.split(' ')[1]);
    if (!payload) return res.status(401).json({ error: 'Geçersiz token' });

    const user = payload.username;
    const friendRows = await dbAll('SELECT user1, user2 FROM friends WHERE user1 = ? OR user2 = ?', user, user);
    const friends = friendRows.map(r => (r.user1 === user ? r.user2 : r.user1));
    await dbRun(
      'INSERT INTO user_presence(username, last_seen_ms) VALUES(?, ?) ON CONFLICT(username) DO UPDATE SET last_seen_ms = EXCLUDED.last_seen_ms',
      user,
      Date.now()
    );
    const pendingRows = await dbAll('SELECT sender FROM friend_requests WHERE receiver = ? AND status = ?', user, 'pending');
    const pendingInviteRows = await dbAll(
      'SELECT id, sender, payload FROM room_invites WHERE recipient = ? AND status = ? ORDER BY created_at, id',
      user,
      'pending'
    );
    const onlineRows = await dbAll('SELECT username FROM user_presence WHERE last_seen_ms >= ? ORDER BY username', Date.now() - 30000);
    const pendingRoomInvites = pendingInviteRows.map((row) => ({
      ...JSON.parse(row.payload),
      invite_id: row.id,
      from: row.sender
    }));

    const eventKey = user.trim().toLowerCase();
    const events = userEvents[eventKey] || [];
    userEvents[eventKey] = [];

    res.json({
      success: true,
      friends,
      pending_requests: pendingRows,
      pending_room_invites: pendingRoomInvites,
      online_users: onlineRows.map((row) => row.username),
      events,
      timestamp: Date.now()
    });
  } catch (e) {
    res.status(500).json({ success: false, error: e.message });
  }
});

/* Create Room & Spawn Godot Binary */
app.post('/api/rooms/create', async (req, res) => {
  try {
    const authHeader = req.headers.authorization;
    if (!authHeader || !authHeader.startsWith('Bearer ')) return res.status(401).json({ error: 'Yetkisiz erişim' });
    const payload = verifyJWT(authHeader.split(' ')[1]);
    if (!payload) return res.status(401).json({ error: 'Geçersiz token' });

    const creator = payload.username;
    const { mode, match_minutes, invitees } = req.body;
    const modeStr = mode || 'free_kick';

    const port = getNextAvailablePort();
    const minutesVal = match_minutes || 10;
    const exePath = process.env.VOIP_3D_EXE || path.resolve(__dirname, '..', 'voip-3d', 'voip-3d.exe');
    const args = [
      '--headless',
      '--server',
      '--host', '192.168.1.9',
      '--port', port.toString(),
      '--mode', modeStr,
      '--minutes', minutesVal.toString(),
      '--transport', 'ws'
    ];

    console.log(`[RoomManager] Spawning game server binary: ${exePath} ${args.join(' ')}`);

    let proc = null;
    let procError = null;
    try {
      proc = spawn(exePath, args, { cwd: path.dirname(exePath) });
      proc.on('error', (error) => {
        procError = error;
        console.error(`[RoomManager] Game server on port ${port} failed to spawn:`, error);
      });
      proc.stdout.on('data', (data) => console.log(`[GodotServer:${port}] ${data}`));
      proc.stderr.on('data', (data) => console.error(`[GodotServer:${port}] ${data}`));
    } catch (err) {
      console.error('[RoomManager] Failed to spawn binary:', err);
      return res.status(500).json({ success: false, error: 'Oda sunucu binarysi çalıştırılamadı.' });
    }

    const roomId = `room_${Date.now()}_${port}`;
    const token = Math.random().toString(36).substring(2, 10) + Math.random().toString(36).substring(2, 10);

    const roomInfo = {
      id: roomId,
      creator,
      mode: modeStr,
      minutes: minutesVal,
      port,
      host: SERVER_HOST,
      token,
      process: proc
    };

    activeRooms[roomId] = roomInfo;

    if (proc) {
      proc.on('exit', (code) => {
        console.log(`[RoomManager] Game server on port ${port} exited with code ${code}`);
        delete activeRooms[roomId];
      });
    }

    try {
      await waitForRoomPort(port);
    } catch (error) {
      delete activeRooms[roomId];
      if (proc && proc.exitCode === null && proc.signalCode === null) proc.kill();
      return res.status(503).json({ success: false, error: `Oda sunucusu başlatılamadı: ${(procError || error).message}` });
    }

    const inviteeNames = Array.isArray(invitees)
      ? [...new Set(invitees.filter((name) => typeof name === 'string').map((name) => name.trim()).filter(Boolean))]
      : [];
    try {
      for (const friendName of inviteeNames) {
        const target = await dbGet('SELECT username FROM users WHERE LOWER(username) = LOWER(?)', friendName);
        if (!target || target.username.toLowerCase() === creator.toLowerCase()) continue;
        const inviteId = crypto.randomUUID();
        const invite = {
          invite_id: inviteId,
          type: 'room_invite',
          from: creator,
          room_id: roomId,
          mode: modeStr,
          match_minutes: minutesVal,
          host: SERVER_HOST,
          port,
          token
        };
        await dbRun(
          'INSERT INTO room_invites(id, sender, recipient, payload) VALUES(?, ?, ?, ?)',
          inviteId,
          creator,
          target.username,
          JSON.stringify(invite)
        );
      }
    } catch (inviteError) {
      delete activeRooms[roomId];
      if (proc && proc.exitCode === null && proc.signalCode === null) proc.kill();
      throw inviteError;
    }

    res.json({
      success: true,
      message: 'Oda sunucuda başarıyla oluşturuldu!',
      roomId,
      host: SERVER_HOST,
      port,
      token,
      mode: modeStr
    });
  } catch (e) {
    console.error('Create room error:', e);
    res.status(500).json({ success: false, error: e.message });
  }
});

app.post('/api/rooms/invites/respond', async (req, res) => {
  try {
    const authHeader = req.headers.authorization;
    if (!authHeader || !authHeader.startsWith('Bearer ')) return res.status(401).json({ error: 'Yetkisiz erişim' });
    const payload = verifyJWT(authHeader.split(' ')[1]);
    if (!payload || !payload.username) return res.status(401).json({ error: 'Geçersiz token' });

    const inviteId = String(req.body.invite_id || '').trim();
    if (!inviteId) return res.status(400).json({ success: false, error: 'Davet kimliği gerekli.' });
    const accept = req.body.accept === true;
    const invite = await dbGet(
      'SELECT id FROM room_invites WHERE id = ? AND recipient = ? AND status = ?',
      inviteId,
      payload.username,
      'pending'
    );
    if (!invite) return res.status(404).json({ success: false, error: 'Bekleyen oda daveti bulunamadı.' });

    await dbRun(
      'UPDATE room_invites SET status = ? WHERE id = ? AND recipient = ? AND status = ?',
      accept ? 'accepted' : 'declined',
      inviteId,
      payload.username,
      'pending'
    );
    res.json({ success: true });
  } catch (e) {
    res.status(500).json({ success: false, error: e.message });
  }
});

app.post('/api/rooms/shared', async (req, res) => {
  try {
    const authHeader = req.headers.authorization;
    if (!authHeader || !authHeader.startsWith('Bearer ')) return res.status(401).json({ error: 'Yetkisiz erişim' });
    const payload = verifyJWT(authHeader.split(' ')[1]);
    if (!payload || !payload.username) return res.status(401).json({ error: 'Geçersiz token' });

    const sharedMode = String(req.body.mode || '');
    const modes = {
      plaza: { mode: 'conference', minutes: 60 },
      match: { mode: 'match', minutes: 10 },
      free_kick: { mode: 'free_kick', minutes: 10 },
      overland: { mode: 'overland', minutes: 60, port: 12897 }
    };
    const portalId = String(req.body.portal_id || '').trim();
    const portalModes = {
      free_kick: { mode: 'free_kick', minutes: 10, firstPort: 12882 },
      match: { mode: 'match', minutes: 10, firstPort: 12887 },
      conference: { mode: 'conference', minutes: 60, firstPort: 12892 }
    };
    const portalRooms = {};
    for (const [portalMode, settings] of Object.entries(portalModes)) {
      for (let index = 1; index <= 5; index++) {
        const portalKey = `${portalMode}_${String(index).padStart(2, '0')}`;
        portalRooms[portalKey] = {
          mode: settings.mode,
          minutes: settings.minutes,
          port: settings.firstPort + index - 1
        };
      }
    }
    const roomSettings = portalId
      ? portalRooms[portalId]
      : (Object.hasOwn(modes, sharedMode) ? modes[sharedMode] : null);
    if (portalId && roomSettings && roomSettings.mode !== sharedMode) {
      return res.status(400).json({ success: false, error: 'Portal türüyle oda türü eşleşmiyor.' });
    }
    if (!roomSettings) return res.status(400).json({ success: false, error: 'Geçersiz ortak oda türü.' });
    const roomKey = portalId ? `portal_${portalId}` : sharedMode;

    if (process.env.SERVER_SHARED_ROOM_IPC === '1' && typeof process.send === 'function') {
      const requestId = crypto.randomUUID();
      const sharedRoom = await new Promise((resolve, reject) => {
        const timeout = setTimeout(() => {
          process.off('message', handleResponse);
          reject(new Error('Ortak oda yöneticisinden zamanında yanıt alınamadı.'));
        }, 25000);
        const handleResponse = (message) => {
          if (!message || message.type !== 'shared-room-response' || message.requestId !== requestId) return;
          clearTimeout(timeout);
          process.off('message', handleResponse);
          if (message.error) reject(new Error(message.error));
          else resolve(message.room);
        };
        process.on('message', handleResponse);
        process.send({
          type: 'shared-room-request',
          requestId,
          mode: sharedMode,
          portal_id: portalId,
          creator: payload.username
        }, (error) => {
          if (error) {
            clearTimeout(timeout);
            process.off('message', handleResponse);
            reject(error);
          }
        });
      });
      return res.json(sharedRoom);
    }

    let roomInfo = sharedRooms[roomKey];
    if (!roomInfo || !roomInfo.process || roomInfo.process.exitCode !== null || roomInfo.process.signalCode !== null) {
      const port = roomSettings.port || getNextAvailablePort();
      const exePath = process.env.VOIP_3D_EXE || path.resolve(__dirname, '..', 'voip-3d', 'voip-3d.exe');
      const args = [
        '--headless',
        '--server',
        '--host', SERVER_HOST,
        '--port', port.toString(),
        '--mode', roomSettings.mode,
        '--minutes', roomSettings.minutes.toString(),
        '--transport', 'ws'
      ];
      const proc = spawn(exePath, args, { cwd: path.dirname(exePath) });
      const roomId = `shared_${roomKey}_${port}`;
      roomInfo = {
        id: roomId,
        creator: payload.username,
        mode: roomSettings.mode,
        minutes: roomSettings.minutes,
        port,
        host: SERVER_HOST,
        token: '',
        process: proc
      };
      sharedRooms[roomKey] = roomInfo;
      activeRooms[roomId] = roomInfo;

      proc.stdout.on('data', (data) => console.log(`[GodotServer:${port}] ${data}`));
      proc.stderr.on('data', (data) => console.error(`[GodotServer:${port}] ${data}`));
      proc.on('error', (error) => {
        console.error(`[RoomManager] Shared server failed to start (${sharedMode}):`, error);
        if (sharedRooms[roomKey] === roomInfo) delete sharedRooms[roomKey];
        delete activeRooms[roomId];
      });
      proc.on('exit', (code) => {
        console.log(`[RoomManager] Shared game server on port ${port} exited with code ${code}`);
        if (sharedRooms[roomKey] === roomInfo) delete sharedRooms[roomKey];
        delete activeRooms[roomId];
      });

      try {
        await new Promise((resolve, reject) => {
          proc.once('spawn', resolve);
          proc.once('error', reject);
        });
      } catch (error) {
        console.error(`[RoomManager] Could not spawn shared server (${sharedMode}):`, error);
        return res.status(500).json({ success: false, error: 'Ortak oda sunucusu başlatılamadı.' });
      }
    }

    try {
      await waitForRoomPort(roomInfo.port);
    } catch (error) {
      if (roomInfo.process && roomInfo.process.exitCode === null) roomInfo.process.kill();
      if (sharedRooms[roomKey] === roomInfo) delete sharedRooms[roomKey];
      delete activeRooms[roomInfo.id];
      console.error(`[RoomManager] Shared server did not become ready (${sharedMode}):`, error);
      return res.status(503).json({ success: false, error: 'Ortak oda sunucusu zamanında hazır olmadı.' });
    }

    return res.json({
      success: true,
      message: 'Ortak oda hazır.',
      roomId: roomInfo.id,
      host: roomInfo.host,
      port: roomInfo.port,
      token: roomInfo.token,
      mode: roomInfo.mode
    });
  } catch (e) {
    console.error('Shared room error:', e);
    return res.status(500).json({ success: false, error: e.message });
  }
});

/* exec endpoint: send an action to agent(s) */
//const SAFE_ACTIONS = new Set(['PING', 'STATUS', 'RELOAD_WHITELIST', 'PSLIST', 'EXEC:']);
// app.post('/exec', requireAuth, body('action').isString().trim().isLength({ min: 1, max: 200 }), body('agent').optional().isString().trim().isLength({ min: 1, max: 100 }), async (req, res) => {
//   const errors = validationResult(req);
//   if (!errors.isEmpty()) return res.status(400).json({ ok: false, error: 'invalid' });
//   let action = (req.body.action || '').toString().trim();
//   const agent = (req.body.agent || 'ALL').toString().trim();

//   // If action is "EXEC:" (means exec PSLIST?), server expects exact command string override
//   if (action === 'EXEC:') {
//     // rely on req.body.komiksey for command content (as you used earlier)
//     const kom = (req.body.komiksey || '').toString();
//     if (!kom) return res.status(400).json({ ok: false, error: 'no command' });
//     action = `EXEC:${kom}`;
//   }

//   try {
//     const payloadObj = (action.startsWith('EXEC:') && action.length > 5) ? { type: 'exec_request', cmd: action } : { type: 'cmd', cmd: action };
//     if (agent === 'ALL') {
//       for (const [name, meta] of Object.entries(agents)) {
//         try {
//           const enc = encryptMessage(JSON.stringify(payloadObj));
//           const header = Buffer.alloc(4); header.writeUInt32BE(enc.length, 0);
//           meta.socket.write(Buffer.concat([header, enc]));
//         } catch (e) {
//           pushEvent(`Broadcast to ${name} failed: ${e.message}`, 'error');
//         }
//       }
//       pushEvent(`Broadcast action ${action}`, 'command');
//       return res.json({ ok: true });
//     } else {
//       if (!agents[agent]) return res.status(404).json({ ok: false, error: 'agent not found' });
//       const meta = agents[agent];
//       const enc = encryptMessage(JSON.stringify(payloadObj));
//       const header = Buffer.alloc(4); header.writeUInt32BE(enc.length, 0);
//       meta.socket.write(Buffer.concat([header, enc]));
//       pushEvent(`Action ${action} sent to ${agent}`, 'command');
//       return res.json({ ok: true });
//     }
//   } catch (e) {
//     pushEvent(`Exec send error: ${e.message}`, 'error');
//     return res.status(500).json({ ok: false, error: e.message });
//   }
// });
// exec endpoint (agent.ejs’ten gelen komutları agent’a yollar)
app.post('/exec',
  requireAuth,
  body('action').isString().trim().isLength({ min: 1, max: 200 }),
  body('agent').optional().isString().trim().isLength({ min: 1, max: 100 }),
  async (req, res) => {
    const errors = validationResult(req);
    if (!errors.isEmpty())
      return res.status(400).json({ ok: false, error: 'invalid' });

    const action = (req.body.action || '').trim();
    const agent = (req.body.agent || 'ALL').trim();
    const value = (req.body.value || '').trim();

    try {
      const payloadObj = value
        ? { type: 'cmd', cmd: action, value }
        : { type: 'cmd', cmd: action };

      if (agent === 'ALL') {
        for (const [name, meta] of Object.entries(agents)) {
          try {
            const enc = encryptMessage(JSON.stringify(payloadObj));
            const header = Buffer.alloc(4);
            header.writeUInt32BE(enc.length, 0);
            meta.socket.write(Buffer.concat([header, enc]));
          } catch (e) {
            pushEvent(`Broadcast to ${name} failed: ${e.message}`, 'error');
          }
        }
        pushEvent(`Broadcast action ${action}`, 'command');
        return res.json({ ok: true });
      } else {
        if (!agents[agent])
          return res.status(404).json({ ok: false, error: 'agent not found' });
        const meta = agents[agent];
        const enc = encryptMessage(JSON.stringify(payloadObj));
        const header = Buffer.alloc(4);
        header.writeUInt32BE(enc.length, 0);
        meta.socket.write(Buffer.concat([header, enc]));
        pushEvent(`Action ${action} sent to ${agent}`, 'command');
        return res.json({ ok: true });
      }
    } catch (e) {
      pushEvent(`Exec send error: ${e.message}`, 'error');
      return res.status(500).json({ ok: false, error: e.message });
    }
  }
);


/* health / recent endpoints */
app.get('/recent', requireAuth, (req, res) => res.json(recent.slice(-200)));
app.get('/health', (req, res) => res.json({ ok: true, ts: Date.now(), agents: Object.keys(agents).length }));

/* error rendering route */
app.get('/error', (req, res) => res.render('error', { error: 'Bir hata oluştu.' }));

/* ---------- Real-Time WebSocket Server (/ws) ---------- */
const WebSocket = require('ws');
const wss = new WebSocket.Server({ noServer: true });
const wsClients = new Map(); // username -> ws

server.on('upgrade', (request, socket, head) => {
  const pathname = new URL(request.url, `http://${request.headers.host}`).pathname;
  if (pathname === '/ws') {
    wss.handleUpgrade(request, socket, head, (ws) => {
      wss.emit('connection', ws, request);
    });
  }
});

wss.on('connection', (ws) => {
  let currentUser = null;

  ws.on('message', async (message) => {
    try {
      const data = JSON.parse(message.toString());
      const { type } = data;

      if (type === 'auth') {
        const payload = verifyJWT(data.token);
        if (payload && payload.username) {
          currentUser = payload.username.trim();
          const authKey = currentUser.toLowerCase();
          wsClients.set(authKey, ws);
          ws.send(JSON.stringify({ type: 'auth_ok', username: currentUser }));

          const friendRows = await dbAll('SELECT user1, user2 FROM friends WHERE user1 = ? OR user2 = ?', currentUser, currentUser);
          const friends = friendRows.map(r => (r.user1 === currentUser ? r.user2 : r.user1));
          const pendingRows = await dbAll('SELECT sender FROM friend_requests WHERE receiver = ? AND status = "pending"', currentUser);
          ws.send(JSON.stringify({ type: 'sync_state', friends, pending_requests: pendingRows }));

          const queued = userEvents[authKey] || [];
          userEvents[authKey] = [];
          queued.forEach(ev => ws.send(JSON.stringify(ev)));
        } else {
          ws.send(JSON.stringify({ type: 'auth_error', message: 'Geçersiz token' }));
        }
        return;
      }

      if (!currentUser) return;

      // 1. Search Users
      if (type === 'search_users') {
        const q = (data.term || '').trim();
        const rows = q ? await dbAll('SELECT username, avatar_url FROM users WHERE username LIKE ? LIMIT 20', `%${q}%`) : [];
        ws.send(JSON.stringify({ type: 'search_results', users: rows }));
      }

      // 2. Friend Request
      else if (type === 'friend_request') {
        const { targetUsername } = data;
        if (targetUsername && targetUsername.trim().toLowerCase() !== currentUser.toLowerCase()) {
          const target = await dbGet('SELECT username FROM users WHERE username = ?', targetUsername.trim());
          if (target) {
            await dbRun('INSERT INTO friend_requests (sender, receiver, status) VALUES (?, ?, "pending")', currentUser, target.username);
            const reqEv = { type: 'friend_request', from: currentUser };
            queueUserEvent(target.username, reqEv);
            const targetWs = wsClients.get(target.username.toLowerCase());
            if (targetWs && targetWs.readyState === WebSocket.OPEN) {
              targetWs.send(JSON.stringify(reqEv));
            }
          }
        }
      }

      // 3. Respond Friend Request
      else if (type === 'friend_respond') {
        const { targetUsername, accept } = data;
        if (targetUsername) {
          await dbRun('UPDATE friend_requests SET status = ? WHERE sender = ? AND receiver = ?', accept ? 'accepted' : 'declined', targetUsername.trim(), currentUser);
          if (accept) {
            const u1 = currentUser.toLowerCase() < targetUsername.trim().toLowerCase() ? currentUser : targetUsername.trim();
            const u2 = currentUser.toLowerCase() < targetUsername.trim().toLowerCase() ? targetUsername.trim() : currentUser;
            await dbRun('INSERT OR IGNORE INTO friends (user1, user2) VALUES (?, ?)', u1, u2);

            const acceptEv = { type: 'friend_accepted', from: currentUser };
            queueUserEvent(targetUsername.trim(), acceptEv);
            ws.send(JSON.stringify({ type: 'friend_accepted', from: targetUsername.trim() }));
            const targetWs = wsClients.get(targetUsername.trim().toLowerCase());
            if (targetWs && targetWs.readyState === WebSocket.OPEN) {
              targetWs.send(JSON.stringify(acceptEv));
            }
          }
        }
      }

      // 4. Send Direct Message / Chat
      else if (type === 'send_chat') {
        const { recipient, message: chatMsg } = data;
        if (recipient && chatMsg) {
          await dbRun('INSERT INTO messages (sender, recipient, message) VALUES (?, ?, ?)', currentUser, recipient.trim(), chatMsg);
          ws.send(JSON.stringify({ type: 'chat_message', sender: currentUser, recipient: recipient.trim(), message: chatMsg, local_echo: true }));
          const chatEv = { type: 'chat_message', sender: currentUser, recipient: currentUser, message: chatMsg, local_echo: false };
          queueUserEvent(recipient.trim(), chatEv);
          const targetWs = wsClients.get(recipient.trim().toLowerCase());
          if (targetWs && targetWs.readyState === WebSocket.OPEN) {
            targetWs.send(JSON.stringify(chatEv));
          }
        }
      }

      // 5. Create Room & Room Invites
      else if (type === 'create_room') {
        const { mode, match_minutes, invitees } = data;
        const modeStr = mode || 'free_kick';

        const port = getNextAvailablePort();
        const minutesVal = match_minutes || 10;
        const exePath = process.env.VOIP_3D_EXE || path.resolve(__dirname, '..', 'voip-3d', 'voip-3d.exe');
        const args = [
          '--headless',
          '--server',
          '--host', '192.168.1.9',
          '--port', port.toString(),
          '--mode', modeStr,
          '--minutes', minutesVal.toString(),
          '--transport', 'ws'
        ];

        let proc = null;
        try {
          proc = spawn(exePath, args, { cwd: path.dirname(exePath) });
          proc.stdout.on('data', (d) => {
            d.toString().split('\n').forEach(line => {
              if (line.trim()) console.log(`[GodotServer:${port}] ${line.trim()}`);
            });
          });
          proc.stderr.on('data', (d) => {
            d.toString().split('\n').forEach(line => {
              if (line.trim()) console.error(`[GodotServer:${port}] ${line.trim()}`);
            });
          });
        } catch (e) {
          console.error('[RoomManager] Failed to spawn binary:', e);
          return ws.send(JSON.stringify({ type: 'error', message: 'Oda başlatılamadı' }));
        }

        const roomId = `room_${Date.now()}_${port}`;
        const token = Math.random().toString(36).substring(2, 10) + Math.random().toString(36).substring(2, 10);
        activeRooms[roomId] = { id: roomId, creator: currentUser, mode: modeStr, minutes: minutesVal, port, host: '192.168.1.9', token, process: proc };

        if (proc) {
          proc.on('exit', (code) => {
            console.log(`[RoomManager] Game server on port ${port} exited code ${code}`);
            delete activeRooms[roomId];
          });
        }

        ws.send(JSON.stringify({ type: 'room_created', roomId, host: '192.168.1.9', port, token, mode: modeStr }));

        if (Array.isArray(invitees)) {
          invitees.forEach(friendName => {
            const cleanFriend = friendName.trim();
            const inviteEv = {
              type: 'room_invite',
              from: currentUser,
              mode: modeStr,
              match_minutes: minutesVal,
              host: '192.168.1.9',
              port,
              token
            };
            queueUserEvent(cleanFriend, inviteEv);
            const friendWs = wsClients.get(cleanFriend.toLowerCase());
            if (friendWs && friendWs.readyState === WebSocket.OPEN) {
              friendWs.send(JSON.stringify(inviteEv));
            }
          });
        }
      }
    } catch (e) {
      console.error('[WS] Message error:', e);
    }
  });

  ws.on('close', () => {
    if (currentUser) {
      wsClients.delete(currentUser.trim().toLowerCase());
    }
  });
});

/* start http server */
server.listen(HTTP_PORT, '0.0.0.0', () => {
  pushEvent(`HTTP UI listening on http://0.0.0.0:${HTTP_PORT}`, 'info');
});

/* ---------- graceful shutdown ---------- */
let shuttingDown = false;
function shutdown() {
  if (shuttingDown) return;
  shuttingDown = true;
  pushEvent('Shutting down', 'info');
  for (const a of Object.values(agents)) {
    try { a.socket.destroy(); } catch (e) {}
  }
  for (const room of Object.values(activeRooms)) {
    if (room.process && room.process.exitCode === null) {
      room.process.kill();
    }
  }
  server.close();
  tcpServer.close();
  process.exit(0);
}
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
