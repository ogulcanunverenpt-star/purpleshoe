'use strict';

const cluster = require('node:cluster');
const os = require('node:os');
const process = require('node:process');
const crypto = require('node:crypto');
const { spawn } = require('node:child_process');
const { issueMatrixHandoffTicket, redeemMatrixHandoffTicket } = require('./matrix_handoff_store');
const { gameServerLaunch, ensurePortAvailable, waitForGameServer } = require('./game_server_launch');
require('dotenv').config();

if (cluster.isPrimary) {
  let shuttingDown = false;
  process.env.SESSION_SECRET = process.env.SESSION_SECRET || crypto.randomBytes(32).toString('hex');
  process.env.JWT_SECRET = process.env.JWT_SECRET || crypto.randomBytes(32).toString('hex');
  const sharedRooms = new Map();
  const startingRooms = new Map();
  const reservedPorts = new Map();
  const sharedRoomModes = {
    plaza: { mode: 'conference', minutes: 60, port: 12900 },
    match: { mode: 'match', minutes: 10, port: 12899 },
    free_kick: { mode: 'free_kick', minutes: 10, port: 12898 },
    overland: { mode: 'overland', minutes: 60, port: 12897 }
  };
  const portalRoomModes = {};
  const portalRoomGroups = [
    { mode: 'free_kick', minutes: 10, firstPort: 12882 },
    { mode: 'match', minutes: 10, firstPort: 12887 },
    { mode: 'conference', minutes: 60, firstPort: 12892 }
  ];
  for (const group of portalRoomGroups) {
    for (let index = 1; index <= 5; index++) {
      const portalId = `${group.mode}_${String(index).padStart(2, '0')}`;
      portalRoomModes[portalId] = {
        mode: group.mode,
        minutes: group.minutes,
        port: group.firstPort + index - 1
      };
    }
  }
  const serverHost = process.env.SERVER_HOST || '127.0.0.1';

  function sendSharedRoomResponse(worker, requestId, room, error = '') {
    if (worker.isConnected()) {
      worker.send({ type: 'shared-room-response', requestId, room, error });
    }
  }

  async function startSharedRoom(roomKey, settings) {
    if (startingRooms.has(roomKey)) return startingRooms.get(roomKey);
    const starting = doStartSharedRoom(roomKey, settings);
    startingRooms.set(roomKey, starting);
    try {
      return await starting;
    } finally {
      if (startingRooms.get(roomKey) === starting) startingRooms.delete(roomKey);
    }
  }

  async function doStartSharedRoom(roomKey, settings) {
    let room = sharedRooms.get(roomKey);
    if (!room || room.process.exitCode !== null || room.process.signalCode !== null) {
      await ensurePortAvailable(settings.port);
      if (shuttingDown) throw new Error('Server is shutting down.');
      const launch = gameServerLaunch();
      const args = [
        ...launch.prefixArgs,
        '--server',
        '--host', serverHost,
        '--port', settings.port.toString(),
        '--mode', settings.mode,
        '--minutes', settings.minutes.toString(),
        '--transport', 'ws'
      ];
      const child = spawn(launch.command, args, { cwd: launch.cwd });
      room = {
        id: `shared_${roomKey}_${settings.port}`,
        mode: settings.mode,
        port: settings.port,
        host: serverHost,
        token: '',
        process: child,
        ready: waitForGameServer(child, settings.port)
      };
      sharedRooms.set(roomKey, room);

      child.stdout.on('data', (data) => console.log(`[GodotServer:${settings.port}] ${data}`));
      child.stderr.on('data', (data) => console.error(`[GodotServer:${settings.port}] ${data}`));
      child.on('error', (error) => {
        console.error(`[Cluster Primary] Shared server failed (${roomKey}):`, error);
        if (sharedRooms.get(roomKey) === room) sharedRooms.delete(roomKey);
      });
      child.on('exit', (code) => {
        console.log(`[Cluster Primary] Shared game server on port ${settings.port} exited with code ${code}`);
        if (sharedRooms.get(roomKey) === room) sharedRooms.delete(roomKey);
      });

    }

    try {
      await room.ready;
      if (room.process.exitCode !== null || room.process.signalCode !== null) {
        throw new Error(`Game server on port ${room.port} exited.`);
      }
      return room;
    } catch (error) {
      if (room.process.exitCode === null) room.process.kill();
      if (sharedRooms.get(roomKey) === room) sharedRooms.delete(roomKey);
      throw error;
    }
  }

  async function getSharedRoom(worker, request) {
    const portalId = String(request.portal_id || '');
    const settings = portalId
      ? (Object.hasOwn(portalRoomModes, portalId) ? portalRoomModes[portalId] : null)
      : (Object.hasOwn(sharedRoomModes, request.mode) ? sharedRoomModes[request.mode] : null);
    if (settings && portalId && settings.mode !== request.mode) {
      sendSharedRoomResponse(worker, request.requestId, null, 'Portal türüyle oda türü eşleşmiyor.');
      return;
    }
    if (!settings) {
      sendSharedRoomResponse(worker, request.requestId, null, 'Geçersiz ortak oda türü.');
      return;
    }

    const roomKey = portalId ? `portal_${portalId}` : request.mode;
    let room;
    try {
      room = await startSharedRoom(roomKey, settings);
    } catch (error) {
      console.error(`[Cluster Primary] Could not start ${roomKey}:`, error);
      sendSharedRoomResponse(worker, request.requestId, null, 'Ortak oda sunucusu başlatılamadı.');
      return;
    }
    sendSharedRoomResponse(worker, request.requestId, {
      success: true,
      message: 'Ortak oda hazır.',
      roomId: room.id,
      host: room.host,
      port: room.port,
      token: room.token,
      mode: room.mode
    });
  }

  cluster.on('fork', (worker) => {
    worker.on('message', (message) => {
      if (message && message.type === 'shared-room-request') {
        getSharedRoom(worker, message);
      } else if (message && message.type === 'room-port-request') {
        let port = null;
        for (let candidate = 12810; candidate <= 12849; candidate++) {
          if (!reservedPorts.has(candidate)) {
            port = candidate;
            reservedPorts.set(port, worker.id);
            break;
          }
        }
        worker.send({ type: 'room-port-response', requestId: message.requestId, port });
      } else if (message && message.type === 'room-port-release') {
        if (reservedPorts.get(message.port) === worker.id) reservedPorts.delete(message.port);
      } else if (message && message.type === 'matrix-handoff-issue-request') {
        try {
          const handoff = issueMatrixHandoffTicket(message.session);
          worker.send({
            type: 'matrix-handoff-response',
            requestId: message.requestId,
            response: { success: true, ...handoff }
          });
        } catch (error) {
          console.error('Could not issue Matrix handoff ticket:', error.message);
          worker.send({
            type: 'matrix-handoff-response',
            requestId: message.requestId,
            response: { success: false }
          });
        }
      } else if (message && message.type === 'matrix-handoff-redeem-request') {
        try {
          const session = redeemMatrixHandoffTicket(message.ticket);
          worker.send({
            type: 'matrix-handoff-response',
            requestId: message.requestId,
            response: session ? { success: true, session } : { success: false }
          });
        } catch (error) {
          console.error('Could not redeem Matrix handoff ticket:', error.message);
          worker.send({
            type: 'matrix-handoff-response',
            requestId: message.requestId,
            response: { success: false }
          });
        }
      }
    });
  });

  async function start() {
    const httpPort = Number(process.env.PORT || process.env.HTTP_PORT || 3000);
    const tcpPort = Number(process.env.TCP_PORT || 8000);
    if (!Number.isInteger(httpPort) || httpPort < 1 || httpPort > 65535 ||
        !Number.isInteger(tcpPort) || tcpPort < 1 || tcpPort > 65535 || httpPort === tcpPort) {
      throw new Error('HTTP and TCP ports must be different valid port numbers.');
    }
    if ([httpPort, tcpPort].some(port => port >= 12810 && port <= 12900)) {
      throw new Error('HTTP and TCP ports must not overlap the game-room range 12810-12900.');
    }
    await ensurePortAvailable(httpPort);
    await ensurePortAvailable(tcpPort);
    for (const [key, settings] of Object.entries(sharedRoomModes)) {
      await startSharedRoom(key, settings);
      console.log(`[Cluster Primary] ${key} ready on ${settings.port}`);
    }
    for (const [key, settings] of Object.entries(portalRoomModes)) {
      await startSharedRoom(`portal_${key}`, settings);
      console.log(`[Cluster Primary] portal ${key} ready on ${settings.port}`);
    }
    const numCPUs = os.availableParallelism ? os.availableParallelism() : os.cpus().length;
    console.log(`[Cluster Primary] Rooms ready. Forking ${numCPUs} workers.`);
    for (let i = 0; i < numCPUs; i++) {
      cluster.fork({ SERVER_SHARED_ROOM_IPC: '1' });
    }
  }

  cluster.on('exit', (worker, code, signal) => {
    for (const [port, owner] of reservedPorts) {
      if (owner === worker.id) reservedPorts.delete(port);
    }
    console.log(`[Cluster Primary] Worker ${worker.process.pid} died (${code || signal}). Restarting replacement worker...`);
    if (!shuttingDown) cluster.fork({ SERVER_SHARED_ROOM_IPC: '1' });
  });

  function shutdown(exitCode = 0) {
    if (shuttingDown) return;
    shuttingDown = true;
    for (const room of sharedRooms.values()) {
      if (room.process.exitCode === null) room.process.kill();
    }
    for (const worker of Object.values(cluster.workers)) {
      if (worker && worker.isConnected()) worker.kill('SIGINT');
    }
    setTimeout(() => process.exit(exitCode), 5000).unref();
  }

  process.on('SIGINT', () => shutdown());
  process.on('SIGTERM', () => shutdown());
  start().catch((error) => {
    console.error('[Cluster Primary] Failed to start game rooms:', error);
    process.exitCode = 1;
    shutdown(1);
  });
} else {
  // Worker process loads server.js logic
  require('./server.js');
}
