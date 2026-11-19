'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');

const source = fs.readFileSync(path.join(__dirname, '..', 'openworld', 'web_voice.js'), 'utf8');

function harness(getUserMedia) {
  const connections = [];
  const contexts = [];
  const signals = [];
  const packets = [];
  const errors = [];
  const events = new Map();
  const window = {
    isSecureContext: true,
    addEventListener(name, callback) { events.set(name, callback); },
    removeEventListener(name) { events.delete(name); }
  };
  class AudioContext {
    constructor() {
      this.sampleRate = 48000;
      this.state = 'running';
      this.destination = {};
      contexts.push(this);
    }
    createMediaStreamSource() { return { connect() {}, disconnect() {} }; }
    createGain() { return { gain: { value: 1 }, connect() {}, disconnect() {} }; }
    createScriptProcessor() {
      this.processor = { connect() {}, disconnect() {}, onaudioprocess: null };
      return this.processor;
    }
    close() { return Promise.resolve(); }
  }
  class RTCPeerConnection {
    constructor() {
      this.remoteDescription = null;
      this.localDescription = null;
      this.operations = [];
      connections.push(this);
    }
    addTransceiver() { return { sender: { replaceTrack: async () => {} } }; }
    async createOffer() { return { type: 'offer' }; }
    async createAnswer() { return { type: 'answer' }; }
    async setLocalDescription(description) { this.localDescription = { ...description, toJSON: () => description }; }
    async setRemoteDescription(description) { this.operations.push('description'); this.remoteDescription = description; }
    async addIceCandidate() { this.operations.push('candidate'); }
    close() { this.closed = true; }
  }
  vm.runInNewContext(source, {
    window, AudioContext, RTCPeerConnection,
    navigator: { mediaDevices: { getUserMedia } },
    btoa: binary => Buffer.from(binary, 'binary').toString('base64'),
    console, Uint8Array, DataView, Promise
  });
  const voice = window.createOverlandVoice(2, JSON.stringify([{ urls: 'stun:example.org' }]),
    value => signals.push(JSON.parse(value)),
    value => packets.push(Buffer.from(value, 'base64')),
    value => errors.push(value));
  return { voice, contexts, connections, signals, packets, errors, events };
}

test('push to talk sends 24 kHz PCM for native peers only while held', async () => {
  const track = { enabled: false, stop() { this.stopped = true; } };
  const stream = { getAudioTracks: () => [track], getTracks: () => [track] };
  const h = harness(async () => stream);
  await h.voice.setTalking(true);
  assert.equal(track.enabled, true);
  const event = { inputBuffer: { getChannelData: () => new Float32Array(2400).fill(0.5) } };
  h.contexts[0].processor.onaudioprocess(event);
  assert.equal(h.packets.length, 1);
  assert.equal(h.packets[0].length, 2400);
  assert.equal(h.packets[0].readInt16LE(0), 16384);
  h.contexts[0].processor.onaudioprocess({
    inputBuffer: { getChannelData: () => new Float32Array(600).fill(0.5) }
  });
  await h.voice.setTalking(false);
  assert.equal(h.packets.length, 2);
  assert.equal(h.packets[1].length, 600);
  h.contexts[0].processor.onaudioprocess(event);
  assert.equal(h.packets.length, 2);
  assert.equal(track.enabled, false);
  h.voice.close();
  assert.equal(track.stopped, true);
  assert.equal(h.events.size, 0);
  assert.deepEqual(h.errors, []);
});

test('releasing push to talk before permission resolves keeps the microphone muted', async () => {
  let resolve;
  const track = { enabled: true, stop() {} };
  const stream = { getAudioTracks: () => [track], getTracks: () => [track] };
  const h = harness(() => new Promise(done => { resolve = done; }));
  const starting = h.voice.setTalking(true);
  await h.voice.setTalking(false);
  resolve(stream);
  await starting;
  assert.equal(track.enabled, false);
  h.voice.close();
  assert.deepEqual(h.errors, []);
});

test('ICE candidates arriving before an offer are applied after its description', async () => {
  const h = harness(async () => { throw new Error('not used'); });
  h.voice.receive(3, JSON.stringify({ candidate: { candidate: 'candidate' } }));
  h.voice.receive(3, JSON.stringify({ description: { type: 'offer', sdp: 'sdp' } }));
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(h.connections[0].operations, ['description', 'candidate']);
  assert.equal(h.signals[0].message.description.type, 'answer');
  h.voice.removePeer(3);
  assert.equal(h.connections[0].closed, true);
  h.voice.close();
  assert.deepEqual(h.errors, []);
});
