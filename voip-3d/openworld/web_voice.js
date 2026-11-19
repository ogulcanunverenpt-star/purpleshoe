(function () {
  "use strict";

  window.createOverlandVoice = function (localId, iceJson, onSignal, onPcm, onError) {
    let config;
    let audio;
    try {
      const iceServers = JSON.parse(iceJson);
      if (!Array.isArray(iceServers) || iceServers.length === 0) throw new Error("ICE server configuration is empty.");
      config = { iceServers };
      audio = new AudioContext();
    } catch (value) {
      onError(String(value && value.message ? value.message : value));
      return null;
    }
    const peers = new Map();
    let active = false;
    let closed = false;
    let track = null;
    let pending = null;
    let source = null;
    let processor = null;
    let silence = null;
    let samples = [];
    let phase = 0;
    let sum = 0;
    let count = 0;
    let peak = 0;

    function error(value) {
      if (!closed) onError(String(value && value.message ? value.message : value));
    }

    function send(id, data) {
      if (!closed) onSignal(JSON.stringify({ target: id, message: data }));
    }

    function createPeer(id) {
      if (peers.has(id)) return peers.get(id);
      const connection = new RTCPeerConnection(config);
      const sender = connection.addTransceiver("audio", { direction: "sendrecv" }).sender;
      const peer = { connection, sender, queued: [], signaling: Promise.resolve(), source: null, panner: null };
      peers.set(id, peer);
      if (track) sender.replaceTrack(track).catch(error);
      connection.onicecandidate = event => {
        if (event.candidate) send(id, { candidate: event.candidate.toJSON() });
      };
      connection.onconnectionstatechange = () => {
        if (connection.connectionState === "failed") error("Voice connection to player " + id + " failed.");
      };
      connection.ontrack = event => {
        if (peer.source) peer.source.disconnect();
        if (peer.panner) peer.panner.disconnect();
        peer.source = audio.createMediaStreamSource(event.streams[0] || new MediaStream([event.track]));
        peer.panner = audio.createPanner();
        peer.panner.panningModel = "equalpower";
        peer.panner.distanceModel = "linear";
        peer.panner.refDistance = 4;
        peer.panner.maxDistance = 28;
        peer.source.connect(peer.panner);
        peer.panner.connect(audio.destination);
      };
      return peer;
    }

    async function addPeer(id) {
      if (closed || id === localId || peers.has(id)) return;
      try {
        const peer = createPeer(id);
        if (localId < id) {
          await peer.connection.setLocalDescription(await peer.connection.createOffer());
          send(id, { description: peer.connection.localDescription.toJSON() });
        }
      } catch (value) {
        error(value);
      }
    }

    function receive(id, json) {
      try {
        const message = JSON.parse(json);
        const peer = createPeer(id);
        peer.signaling = peer.signaling.then(async () => {
          if (closed || peers.get(id) !== peer) return;
          if (message.description) {
            await peer.connection.setRemoteDescription(message.description);
            for (const candidate of peer.queued) await peer.connection.addIceCandidate(candidate);
            peer.queued = [];
            if (message.description.type === "offer") {
              await peer.connection.setLocalDescription(await peer.connection.createAnswer());
              send(id, { description: peer.connection.localDescription.toJSON() });
            }
          } else if (message.candidate) {
            if (peer.connection.remoteDescription) await peer.connection.addIceCandidate(message.candidate);
            else peer.queued.push(message.candidate);
          }
        }).catch(error);
      } catch (value) {
        error(value);
      }
    }

    function removePeer(id) {
      const peer = peers.get(id);
      if (!peer) return;
      peers.delete(id);
      if (peer.source) peer.source.disconnect();
      if (peer.panner) peer.panner.disconnect();
      peer.connection.close();
    }

    function flushPcm() {
      if (samples.length && peak >= 0.005) {
        const bytes = new Uint8Array(samples.length * 2);
        const view = new DataView(bytes.buffer);
        for (let index = 0; index < samples.length; index++) view.setInt16(index * 2, samples[index], true);
        let binary = "";
        for (const byte of bytes) binary += String.fromCharCode(byte);
        onPcm(btoa(binary));
      }
      samples = [];
      peak = 0;
    }

    function capture(event) {
      if (!active || closed) return;
      const input = event.inputBuffer.getChannelData(0);
      for (let i = 0; i < input.length; i++) {
        sum += input[i];
        count++;
        phase += 24000;
        if (phase < audio.sampleRate) continue;
        phase -= audio.sampleRate;
        const value = Math.max(-1, Math.min(1, sum / count));
        peak = Math.max(peak, Math.abs(value));
        samples.push(Math.round(value * 32767));
        sum = 0;
        count = 0;
        if (samples.length === 1200) flushPcm();
      }
    }

    async function setTalking(value) {
      active = value;
      if (!value) {
        if (track) track.enabled = false;
        flushPcm();
        phase = 0;
        sum = 0;
        count = 0;
        peak = 0;
        return;
      }
      try {
        if (!window.isSecureContext || !navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
          throw new Error("Microphone access requires HTTPS and a supported browser.");
        }
        if (audio.sampleRate < 24000) throw new Error("Microphone sample rate is too low.");
        if (audio.state === "suspended") await audio.resume();
        if (!active || closed) return;
        if (!track) {
          if (!pending) pending = navigator.mediaDevices.getUserMedia({ audio: true, video: false });
          const stream = await pending;
          pending = null;
          if (closed) {
            stream.getTracks().forEach(item => item.stop());
            return;
          }
          if (!track) {
            track = stream.getAudioTracks()[0];
            if (!track) throw new Error("No microphone audio track was returned.");
            track.enabled = active;
            source = audio.createMediaStreamSource(stream);
            processor = audio.createScriptProcessor(2048, 1, 1);
            silence = audio.createGain();
            silence.gain.value = 0;
            processor.onaudioprocess = capture;
            source.connect(processor);
            processor.connect(silence);
            silence.connect(audio.destination);
            for (const peer of peers.values()) await peer.sender.replaceTrack(track);
          }
        }
        track.enabled = active;
      } catch (value) {
        pending = null;
        active = false;
        if (track) track.enabled = false;
        error(value);
      }
    }

    const resume = () => {
      if (!closed && audio.state === "suspended") audio.resume().catch(error);
    };
    window.addEventListener("pointerdown", resume);
    window.addEventListener("keydown", resume);
    return {
      addPeer, receive, removePeer, setTalking,
      setPosition(id, x, y, z) {
        const peer = peers.get(id);
        if (!peer || !peer.panner) return;
        peer.panner.positionX.value = x;
        peer.panner.positionY.value = y;
        peer.panner.positionZ.value = z;
      },
      close() {
        if (closed) return;
        closed = true;
        active = false;
        window.removeEventListener("pointerdown", resume);
        window.removeEventListener("keydown", resume);
        if (track) track.stop();
        if (source) source.disconnect();
        if (processor) processor.disconnect();
        if (silence) silence.disconnect();
        for (const id of peers.keys()) removePeer(id);
        audio.close().catch(value => console.error("Voice audio cleanup failed:", value));
      }
    };
  };
})();
