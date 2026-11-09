'use strict';

const assert = require('node:assert/strict');
const { EventEmitter } = require('node:events');
const net = require('node:net');
const { PassThrough } = require('node:stream');
const test = require('node:test');
const { ensurePortAvailable, waitForGameServer } = require('../game_server_launch');

function fakeChild() {
  const child = new EventEmitter();
  child.stdout = new PassThrough();
  return child;
}

test('a listening port cannot be reserved', async () => {
  const server = net.createServer();
  await new Promise(resolve => server.listen(0, '0.0.0.0', resolve));
  try {
    await assert.rejects(ensurePortAvailable(server.address().port), { code: 'EADDRINUSE' });
  } finally {
    await new Promise(resolve => server.close(resolve));
  }
});

test('readiness requires the child to report its own port', async () => {
  const server = net.createServer(socket => socket.destroy());
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  try {
    const port = server.address().port;
    const child = fakeChild();
    const ready = waitForGameServer(child, port);
    child.stdout.write(`ROOM_SERVER_READY ${port + 1}\n`);
    child.emit('exit', 1, null);
    await assert.rejects(ready, /exited before readiness/);

    const healthy = fakeChild();
    const healthyReady = waitForGameServer(healthy, port);
    healthy.stdout.write(`ROOM_SERVER_READY ${port}\n`);
    await healthyReady;
  } finally {
    await new Promise(resolve => server.close(resolve));
  }
});

test('spawn errors are propagated', async () => {
  const child = fakeChild();
  const ready = waitForGameServer(child, 12345);
  child.emit('error', new Error('spawn failed'));
  await assert.rejects(ready, /spawn failed/);
});
