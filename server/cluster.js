'use strict';

const cluster = require('node:cluster');
const os = require('node:os');
const process = require('node:process');
const path = require('node:path');
const net = require('node:net');
const { spawn } = require('node:child_process');
const { issueMatrixHandoffTicket, redeemMatrixHandoffTicket } = require('./matrix_handoff_store');
require('dotenv').config();

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

if (cluster.isPrimary) {
  let shuttingDown = false;
  const sharedRooms = new Map();
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
  const serverHost = process.env.SERVER_HOST || '192.168.1.9';

  function sendSharedRoomResponse(worker, requestId, room, error = '') {
    if (worker.isConnected()) {
      worker.send({ type: 'shared-room-response', requestId, room, error });
    }
  }

  async function getSharedRoom(worker, request) {
    const portalId = String(request.portal_id || '');
    const settings = portalId
      ? portalRoomModes[portalId]
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
    let room = sharedRooms.get(roomKey);
    if (!room || room.process.exitCode !== null || room.process.signalCode !== null) {
      const exePath = process.env.VOIP_3D_EXE || path.resolve(__dirname, '..', 'voip-3d', 'voip-3d.exe');
      const args = [
        '--headless',
        '--server',
        '--host', serverHost,
        '--port', settings.port.toString(),
        '--mode', settings.mode,
        '--minutes', settings.minutes.toString(),
        '--transport', 'ws'
      ];
      const child = spawn(exePath, args, { cwd: path.dirname(exePath) });
      room = {
        id: `shared_${roomKey}_${settings.port}`,
        mode: settings.mode,
        port: settings.port,
        host: serverHost,
        token: '',
        process: child,
        ready: new Promise((resolve, reject) => {
          child.once('spawn', resolve);
          child.once('error', reject);
        })
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
      await waitForRoomPort(room.port);
    } catch (error) {
      if (room.process.exitCode === null) room.process.kill();
      if (sharedRooms.get(roomKey) === room) sharedRooms.delete(roomKey);
      sendSharedRoomResponse(worker, request.requestId, null, 'Ortak oda sunucusu zamanında hazır olmadı.');
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

  const numCPUs = os.availableParallelism ? os.availableParallelism() : os.cpus().length;
  console.log(`[Cluster Primary] Master PID ${process.pid} is running. Forking ${numCPUs} CPU workers for Railway...`);

  for (let i = 0; i < numCPUs; i++) {
    cluster.fork({ SERVER_SHARED_ROOM_IPC: '1' });
  }

  cluster.on('exit', (worker, code, signal) => {
    console.log(`[Cluster Primary] Worker ${worker.process.pid} died (${code || signal}). Restarting replacement worker...`);
    if (!shuttingDown) cluster.fork({ SERVER_SHARED_ROOM_IPC: '1' });
  });

  function shutdown() {
    if (shuttingDown) return;
    shuttingDown = true;
    for (const room of sharedRooms.values()) {
      if (room.process.exitCode === null) room.process.kill();
    }
    for (const worker of Object.values(cluster.workers)) {
      if (worker && worker.isConnected()) worker.kill('SIGINT');
    }
    setTimeout(() => process.exit(0), 5000).unref();
  }

  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);
} else {
  // Worker process loads server.js logic
  require('./server.js');
}
