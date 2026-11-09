'use strict';

const fs = require('node:fs');
const net = require('node:net');
const path = require('node:path');

function ensurePortAvailable(port) {
  return new Promise((resolve, reject) => {
    const probe = net.createServer();
    probe.once('error', reject);
    probe.listen({ host: '0.0.0.0', port, exclusive: true }, () => probe.close(resolve));
  });
}

function waitForGameServer(child, port, timeoutMs = 30000) {
  return new Promise((resolve, reject) => {
    let output = '';
    let checking = false;
    let finished = false;
    let socket;
    const timer = setTimeout(() => finish(new Error(`Game server on port ${port} did not become ready.`)), timeoutMs);
    function finish(error) {
      if (finished) return;
      finished = true;
      clearTimeout(timer);
      if (socket) socket.destroy();
      child.stdout.off('data', onData);
      child.off('error', onError);
      child.off('exit', onExit);
      if (error) reject(error);
      else resolve();
    }
    function onError(error) { finish(error); }
    function onExit(code, signal) {
      finish(new Error(`Game server on port ${port} exited before readiness (${code === null ? signal : code}).`));
    }
    function onData(data) {
      if (checking) return;
      output = (output + data.toString()).slice(-8192);
      if (!output.split(/\r?\n/).some(line => line.trim() === `ROOM_SERVER_READY ${port}`)) return;
      checking = true;
      socket = net.createConnection({ host: '127.0.0.1', port });
      socket.once('connect', () => finish());
      socket.once('error', error => finish(error));
    }
    child.stdout.on('data', onData);
    child.once('error', onError);
    child.once('exit', onExit);
  });
}

function gameServerLaunch() {
  const projectDir = path.resolve(__dirname, '..', 'voip-3d');
  const exportedGame = process.env.VOIP_3D_EXE || path.join(projectDir, 'voip-3d.exe');
  if (process.env.VOIP_3D_EXE || fs.existsSync(exportedGame)) {
    if (!fs.existsSync(exportedGame)) {
      throw new Error(`VOIP_3D_EXE does not exist: ${exportedGame}`);
    }
    return { command: exportedGame, prefixArgs: ['--headless', '--'], cwd: path.dirname(exportedGame) };
  }

  const configPath = path.join(__dirname, 'godot-path.local.json');
  const config = fs.existsSync(configPath) ? JSON.parse(fs.readFileSync(configPath, 'utf8').replace(/^\uFEFF/, '')) : {};
  const command = process.env.GODOT_PATH || config.godotPath || 'godot';
  return { command, prefixArgs: ['--headless', '--path', projectDir, '--'], cwd: projectDir };
}

module.exports = { gameServerLaunch, ensurePortAvailable, waitForGameServer };
