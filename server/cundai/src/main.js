import { CallEvent, GroupCallEvent, GroupCallIntent, GroupCallType, createClient } from "matrix-js-sdk";
import { decryptAttachment, encryptAttachment } from "matrix-encrypt-attachment";
import "./styles.css";
import "./portal.css";

const app = document.querySelector("#app");
const SESSION_KEY = "purpleshoe.session";
const LEGACY_SESSION_KEY = "redshoe.session";
const NOTIFICATIONS_KEY = "purpleshoe.notifications";
const LEGACY_NOTIFICATIONS_KEY = "redshoe.notifications";
const API_BASE_URL = (import.meta.env.VITE_PURPLESHOE_API_BASE_URL || (import.meta.env.DEV ? "http://192.168.1.9:3000" : window.location.origin)).replace(/\/$/, "");
const IS_GAME_PORTAL = new URLSearchParams(window.location.search).get("source") === "godot";
const MATRIX_HANDOFF_TICKET = new URLSearchParams(window.location.hash.slice(1)).get("ps_handoff");
if (MATRIX_HANDOFF_TICKET) history.replaceState(null, "", `${location.pathname}${location.search}`);
const savedSession = localStorage.getItem(SESSION_KEY) || localStorage.getItem(LEGACY_SESSION_KEY);
const saved = savedSession ? JSON.parse(savedSession) : null;
if (savedSession && !localStorage.getItem(SESSION_KEY)) localStorage.setItem(SESSION_KEY, savedSession);
const savedNotifications = localStorage.getItem(NOTIFICATIONS_KEY) || localStorage.getItem(LEGACY_NOTIFICATIONS_KEY);
if (savedNotifications !== null && !localStorage.getItem(NOTIFICATIONS_KEY)) localStorage.setItem(NOTIFICATIONS_KEY, savedNotifications);
const appStartTime = Date.now();
const unreadCounts = new Map();
let client;
let activeRoomId = null;
let rooms = [];
let call = null;
let replyTarget = null;
let recording = null;
const sentStates = new Map();
const failedMessages = [];

const icon = (name) => {
  const paths = {
    plus: '<path d="M12 5v14M5 12h14"/>',
    settings: '<path d="M12 8a4 4 0 1 0 0 8 4 4 0 0 0 0-8Z"/><path d="m19.4 15 .1.1 1.4 1.1-1.4 2.4-1.7-.7a8 8 0 0 1-1.4.8l-.3 1.8h-2.8l-.3-1.8a8 8 0 0 1-1.4-.8l-1.7.7-1.4-2.4L8 15a8 8 0 0 1 0-1.8l-1.5-1.1 1.4-2.4 1.7.7a8 8 0 0 1 1.4-.8l.3-1.8h2.8l.3 1.8a8 8 0 0 1 1.4.8l1.7-.7 1.4 2.4-1.5 1.1a8 8 0 0 1 0 1.8Z" transform="translate(-1 -1)"/>',
    phone: '<path d="M22 16.9v3a2 2 0 0 1-2.2 2 19.8 19.8 0 0 1-8.6-3.1 19.4 19.4 0 0 1-6-6A19.8 19.8 0 0 1 2.1 4.2 2 2 0 0 1 4.1 2h3a2 2 0 0 1 2 1.7l.4 2.8a2 2 0 0 1-.6 1.7L7.6 9.5a16 16 0 0 0 6 6l1.3-1.3a2 2 0 0 1 1.7-.6l2.8.4a2 2 0 0 1 1.6 1.9Z"/>',
    video: '<rect x="3" y="5" width="13" height="14" rx="2"/><path d="m16 10 5-3v10l-5-3z"/>',
    send: '<path d="m22 2-7 20-4-9-9-4Z"/><path d="M22 2 11 13"/>',
    menu: '<path d="M4 6h16M4 12h16M4 18h16"/>',
    back: '<path d="m15 18-6-6 6-6"/>',
    lock: '<rect x="4" y="10" width="16" height="11" rx="2"/><path d="M8 10V7a4 4 0 0 1 8 0v3"/>',
    close: '<path d="m18 6-12 12M6 6l12 12"/>',
    exit: '<path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4"/><path d="m16 17 5-5-5-5M21 12H9"/>',
    attach: '<path d="m21.4 11.1-8.5 8.5a6 6 0 0 1-8.5-8.5l9.2-9.2a4 4 0 0 1 5.7 5.7l-9.2 9.2a2 2 0 0 1-2.8-2.8l8.5-8.5"/>',
    mic: '<rect x="9" y="2" width="6" height="12" rx="3"/><path d="M5 10a7 7 0 0 0 14 0M12 17v5m-4 0h8"/>',
    emoji: '<circle cx="12" cy="12" r="10"/><path d="M8 14s1.5 2 4 2 4-2 4-2M9 9h.01M15 9h.01"/>',
    reply: '<path d="m9 17-5-5 5-5"/><path d="M20 18v-2a4 4 0 0 0-4-4H4"/>',
    pin: '<path d="m16 3 5 5-4 1-4 4-1 4-5-5 4-1 4-4zM2 22l7-7"/>',
    download: '<path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><path d="m7 10 5 5 5-5M12 15V3"/>',
    image: '<rect x="3" y="3" width="18" height="18" rx="2"/><circle cx="8.5" cy="8.5" r="1.5"/><path d="m21 15-5-5L5 21"/>',
  };
  return `<svg viewBox="0 0 24 24" aria-hidden="true">${paths[name] || ""}</svg>`;
};

function escapeHtml(value = "") {
  return String(value).replace(/[&<>"']/g, (char) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[char]);
}

function returnGameButtonMarkup() {
  if (!IS_GAME_PORTAL) return "";
  return `<button type="button" class="return-game-button" aria-label="Return to Game">${icon("back")}<span>Return to Game</span></button>`;
}

function bindReturnGameButton() {
  document.querySelector(".return-game-button")?.addEventListener("click", () => {
    if (typeof window.PurpleShoeGame?.returnToGame === "function") {
      window.PurpleShoeGame.returnToGame();
      return;
    }
    if (typeof window.ipc?.postMessage === "function") {
      window.ipc.postMessage(JSON.stringify({ type: "return_to_game" }));
      return;
    }
    if (window.parent !== window) {
      window.parent.postMessage({ type: "purpleshoe:return-to-game" }, "*");
      return;
    }
    toast("Switch back to the game window to return to the game.");
  });
}

async function redeemMatrixHandoff(ticket) {
  if (import.meta.env.PROD && new URL(API_BASE_URL).protocol !== "https:") {
    throw new Error("Matrix session tickets require HTTPS in production.");
  }
  const response = await fetch(`${API_BASE_URL}/api/matrix/handoff/redeem`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ ticket }),
    cache: "no-store",
    credentials: "omit",
    referrerPolicy: "no-referrer",
  });
  const result = await response.json();
  if (!response.ok || !result.success) {
    throw new Error(result.error || "Could not redeem Matrix session ticket.");
  }
  if (!result.baseUrl || !result.userId || !result.accessToken) {
    throw new Error("Matrix session ticket returned an invalid session.");
  }
  return {
    baseUrl: result.baseUrl,
    userId: result.userId,
    accessToken: result.accessToken,
    deviceId: result.deviceId || "",
  };
}

function initials(value = "RS") {
  return value.replace(/^#/, "").split(/[\s:_-]+/).filter(Boolean).slice(0, 2).map((part) => part[0]).join("").toUpperCase() || "RS";
}

function showLogin(error = "") {
  app.innerHTML = `<main class="login-page"><section class="login-visual"><div class="visual-mark">P<span>.</span></div><div class="visual-copy"><p class="eyebrow">FEDERATED MESSAGING</p><h1>Your conversations<br>start here.</h1><p>Connect on the Matrix network with PurpleShoe.</p></div><div class="visual-foot"><span>OPEN NETWORK · YOUR KEYS</span><span>01 / 04</span></div></section><section class="login-panel"><form id="login-form" class="login-form"><div class="mobile-mark">PURPLE<span>SHOE</span></div><p class="eyebrow">CONNECT TO MATRIX</p><h2>Welcome back.</h2><p class="muted">Log in with your account or use an access token.</p><label>Homeserver URL<input name="homeserver" type="url" value="${escapeHtml(saved?.baseUrl || "https://matrix.gamebler.xyz")}" placeholder="https://matrix.gamebler.xyz" required autocomplete="url"></label><label>Matrix username<input name="user" placeholder="@user:matrix.gamebler.xyz" required autocomplete="username"></label><label>Password<input name="password" type="password" placeholder="••••••••••" required autocomplete="current-password"></label><button class="primary-button login-submit" type="submit">Log in <span>→</span></button><button type="button" class="text-button token-login">Sign in with an access token</button><p class="form-error">${escapeHtml(error)}</p><p class="login-note">PurpleShoe does not host your account. Your credentials are sent to your Matrix homeserver.</p></form></section></main>`;
  app.querySelector("#login-form").addEventListener("submit", loginWithPassword);
  app.querySelector(".token-login").addEventListener("click", loginWithToken);
  if (IS_GAME_PORTAL) {
    app.querySelector(".login-form").insertAdjacentHTML("afterbegin", returnGameButtonMarkup());
    bindReturnGameButton();
  }
}

async function loginWithPassword(event) {
  event.preventDefault();
  const form = new FormData(event.currentTarget);
  const baseUrl = String(form.get("homeserver")).replace(/\/$/, "");
  const button = event.currentTarget.querySelector("button[type=submit]");
  button.disabled = true;
  button.textContent = "Connecting...";
  try {
    const authClient = createClient({ baseUrl });
    const result = await authClient.login("m.login.password", { user: form.get("user"), password: form.get("password") });
    await connect({ baseUrl, userId: result.user_id, accessToken: result.access_token, deviceId: result.device_id });
  } catch (error) {
    showLogin(error.message || "Login failed.");
  }
}

async function loginWithToken() {
  const baseUrl = prompt("Matrix homeserver URL", saved?.baseUrl || "https://matrix.gamebler.xyz");
  if (!baseUrl) return;
  const userId = prompt("Matrix user ID (@user:domain)");
  const accessToken = prompt("Access token");
  if (!userId || !accessToken) return;
  try {
    await connect({ baseUrl: baseUrl.replace(/\/$/, ""), userId, accessToken, deviceId: "REDSHOE" });
  } catch (error) {
    showLogin(error.message || "Could not connect to the server.");
  }
}

async function connect(session) {
  localStorage.setItem(SESSION_KEY, JSON.stringify(session));
  client = createClient({ ...session, timelineSupport: true });
  try {
    const cryptoDatabasePrefix = `redshoe-${session.userId}-${session.deviceId || "default"}`.replace(/[^a-zA-Z0-9_-]/g, "_");
    await client.initRustCrypto({ cryptoDatabasePrefix });
  } catch (error) {
    console.warn("Rust crypto initialization failed", error);
  }
  bindClientEvents();
  renderShell();
  await client.startClient({ initialSyncLimit: 30 });
}

function bindClientEvents() {
  window.addEventListener("focus", handleAndroidLaunch);
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") handleAndroidLaunch();
  });
  client.on("sync", (state) => {
    if (state === "PREPARED" || state === "SYNCING") refreshRooms();
    if (state === "PREPARED") handleAndroidLaunch();
  });
  client.on("Room", refreshRooms);
  client.on("Room.timeline", (event, room, toStartOfTimeline, removed) => {
    if (!room || toStartOfTimeline || removed) return;
    if (room.roomId === activeRoomId) {
      renderMessages();
      if (document.visibilityState === "visible" && event.getSender() !== client.getUserId() && event.getId()) {
        client.sendReadReceipt(event).catch(() => {});
      }
    }
    else if (event.getSender() !== client.getUserId() && event.getType() === "m.room.message") {
      if (event.getTs() >= appStartTime - 15000) {
        const count = unreadCounts.get(room.roomId) || 0;
        unreadCounts.set(room.roomId, count + 1);
        notifyRoom(room, event);
      }
    }
    renderRoomList();
  });
  client.on("Room.receipt", (_event, room) => {
    if (room?.roomId === activeRoomId) renderMessages();
  });
  client.on("Room.name", refreshRooms);
  client.on("RoomState.events", refreshRooms);
  client.on("Call.incoming", receiveCall);
  client.on("GroupCall.incoming", receiveGroupCall);
}

function renderShell() {
  const user = client.getUserId() || "";
  app.innerHTML = `<main class="workspace"><aside class="sidebar"><div class="brand-row"><div class="brand-symbol">P<span>.</span></div><span class="brand-name">PURPLESHOE</span><button class="icon-button mobile-menu" aria-label="Rooms menu">${icon("menu")}</button><button class="icon-button settings-button" aria-label="Settings" title="Settings">${icon("settings")}</button></div><div class="profile-row"><div class="avatar self-avatar">${escapeHtml(initials(user.split(":")[0].slice(1)))}</div><div class="profile-copy"><strong>${escapeHtml(user.split(":")[0].slice(1))}</strong><span>${escapeHtml(user)}</span></div><i class="online-dot"></i></div><div class="section-heading"><span>MESSAGES</span><button class="icon-button add-button" aria-label="Add room or person" title="Add room or person">${icon("plus")}</button></div><div class="room-list" id="room-list"><div class="room-placeholder">Loading rooms...</div></div><div class="sidebar-bottom"><span class="connection-dot"></span><span>Connected to Matrix</span><button class="icon-button logout-button" aria-label="Log out" title="Log out">${icon("exit")}</button></div></aside><section class="chat-area"><header class="chat-header" id="chat-header"><button class="icon-button back-button" aria-label="Rooms">${icon("back")}</button><div class="empty-header-mark">P.</div><div class="header-copy"><strong>PurpleShoe</strong><span>Select a room or start a new chat</span></div><div class="header-actions">${returnGameButtonMarkup()}</div></header><section class="chat-empty" id="chat-empty"><div class="empty-art"><div class="empty-ring ring-one"></div><div class="empty-ring ring-two"></div><div class="empty-center">P<span>.</span></div><span class="orbit orbit-a">MATRIX</span><span class="orbit orbit-b">END-TO-END</span></div><p class="eyebrow">YOUR NETWORK, YOUR VOICE</p><h1>Let's get<br>started.</h1><p>Join a room or start a new chat.</p><button class="primary-button start-chat">Start a chat <span>→</span></button></section><section class="conversation hidden" id="conversation"><div class="message-list" id="message-list"></div><form class="composer" id="composer"><textarea name="message" rows="1" placeholder="Write a message..." aria-label="Message" required></textarea><span class="composer-lock" title="End-to-end encryption status">${icon("lock")}</span><button class="send-button" aria-label="Send" title="Send">${icon("send")}</button></form></section><div class="toast" id="toast" role="status"></div><div class="call-layer hidden" id="call-layer"></div></section><div class="modal-root" id="modal-root"></div></main>`;
  app.querySelector(".settings-button").addEventListener("click", showSettings);
  app.querySelector(".add-button").addEventListener("click", showAddMenu);
  app.querySelector(".start-chat").addEventListener("click", showAddMenu);
  app.querySelector(".logout-button").addEventListener("click", logout);
  app.querySelector(".mobile-menu").addEventListener("click", () => app.querySelector(".sidebar").classList.toggle("sidebar-open"));
  app.querySelector(".back-button").addEventListener("click", () => app.querySelector(".sidebar").classList.add("sidebar-open"));
  bindReturnGameButton();
  app.querySelector("#composer").addEventListener("submit", sendMessage);
  setupComposer();
  refreshRooms();
}

function setupComposer() {
  const composer = document.querySelector("#composer");
  document.querySelector(".chat-area").append(composer);
  document.querySelector("#chat-header").insertAdjacentHTML("afterend", '<section class="pinned-strip hidden" id="pinned-strip"><button type="button" class="pinned-toggle" aria-expanded="false"><span class="pinned-icon">⌁</span><span class="pinned-summary">Pinned messages</span><span class="pinned-count"></span><span class="pinned-chevron">⌄</span></button><div class="pinned-items hidden" id="pinned-items"></div></section>');
  composer.insertAdjacentHTML("beforebegin", '<div class="reply-banner hidden" id="reply-banner"><span id="reply-label"></span><button type="button" class="cancel-reply" aria-label="Cancel reply">×</button></div>');
  composer.insertAdjacentHTML("afterbegin", `<input class="file-input" id="attachment-input" type="file" accept="*/*" aria-label="Attach file"><div class="composer-mode"><span class="mode-led"></span><span id="composer-mode-label">WRITE A MESSAGE</span><span class="mode-hint" id="voice-mode-hint">Record without holding the microphone button; tap again to send</span></div><button type="button" class="composer-tool attach-tool" title="Attach a file, photo, or PDF" aria-label="Attach file">${icon("attach")}</button><button type="button" class="composer-tool record-tool" title="Record voice message" aria-label="Record voice message">${icon("mic")}</button><button type="button" class="composer-tool emoji-tool" title="Add emoji" aria-label="Add emoji">${icon("emoji")}</button><div class="emoji-menu hidden" id="emoji-menu">${["😀", "❤️", "👍", "😂", "🎉", "🙏"].map((emoji) => `<button type="button" data-emoji="${emoji}">${emoji}</button>`).join("")}</div>`);
  composer.querySelector(".attach-tool").addEventListener("click", () => document.querySelector("#attachment-input").click());
  document.querySelector("#attachment-input").addEventListener("change", async (event) => {
    const file = event.target.files?.[0];
    if (file) await sendAttachment(file);
    event.target.value = "";
  });
  composer.querySelector(".record-tool").addEventListener("click", toggleVoiceRecording);
  document.querySelector(".pinned-toggle").addEventListener("click", togglePinnedList);
  composer.querySelector(".emoji-tool").addEventListener("click", () => document.querySelector("#emoji-menu").classList.toggle("hidden"));
  document.querySelectorAll("#emoji-menu [data-emoji]").forEach((button) => button.addEventListener("click", () => {
    const input = composer.elements.message;
    input.value += button.dataset.emoji;
    input.focus();
    document.querySelector("#emoji-menu").classList.add("hidden");
  }));
  document.querySelector(".cancel-reply").addEventListener("click", clearReplyTarget);
  document.querySelector("#message-list").addEventListener("click", handleMessageAction);
  setComposerEnabled(false);
}

function setComposerEnabled(enabled) {
  const composer = document.querySelector("#composer");
  if (!composer) return;
  composer.elements.message.disabled = !enabled;
  composer.elements.message.placeholder = enabled ? "Write a message..." : "Select a room before sending a message";
  composer.querySelectorAll("button").forEach((button) => { button.disabled = !enabled; });
  composer.querySelector("#attachment-input").disabled = !enabled;
}

function refreshRooms() {
  if (!client) return;
  rooms = client.getRooms().filter((room) => room.getMyMembership() === "join").sort((a, b) => {
    const aEvent = a.getLiveTimeline().getEvents().at(-1)?.getTs() || 0;
    const bEvent = b.getLiveTimeline().getEvents().at(-1)?.getTs() || 0;
    return bEvent - aEvent;
  });
  renderRoomList();
  if (activeRoomId) renderMessages();
}

function roomPreview(room) {
  const last = [...room.getLiveTimeline().getEvents()].reverse().find((event) => event.getType() === "m.room.message");
  return last?.getContent()?.body || "No messages yet";
}

function renderRoomList() {
  const list = document.querySelector("#room-list");
  if (!list) return;
  const invitations = client.getRooms().filter((room) => room.getMyMembership() === "invite");
  if (!rooms.length && !invitations.length) {
    list.innerHTML = '<div class="room-placeholder">You do not have any rooms yet.<br>Start a new chat.</div>';
    return;
  }
  const invitationHtml = invitations.map((room) => `<div class="room-item invite-item"><span class="avatar room-avatar">${escapeHtml(initials(room.name))}</span><span class="room-details"><strong>${escapeHtml(room.name || room.roomId)}</strong><small>Invited</small></span><button class="invite-choice accept-invite" data-invite="${escapeHtml(room.roomId)}" aria-label="Accept invite">✓</button><button class="invite-choice decline-invite" data-decline="${escapeHtml(room.roomId)}" aria-label="Decline invite">×</button></div>`).join("");
  list.innerHTML = invitationHtml + rooms.map((room) => {
    const count = unreadCounts.get(room.roomId) || room.getUnreadNotificationCount?.("total") || 0;
    const badgeMarkup = count > 0 ? `<span class="unread-badge">${count > 99 ? "99+" : count}</span>` : "";
    return `<button class="room-item ${room.roomId === activeRoomId ? "selected" : ""}" data-room="${escapeHtml(room.roomId)}"><span class="avatar room-avatar">${escapeHtml(initials(room.name))}</span><span class="room-details"><strong>${escapeHtml(room.name || room.roomId)}</strong><small>${escapeHtml(roomPreview(room))}</small></span>${room.hasEncryptionStateEvent() ? `<span class="room-lock">${icon("lock")}</span>` : ""}${badgeMarkup}</button>`;
  }).join("");
  list.querySelectorAll("[data-room]").forEach((button) => button.addEventListener("click", () => openRoom(button.dataset.room)));
  list.querySelectorAll("[data-invite]").forEach((button) => button.addEventListener("click", async () => {
    try { await client.joinRoom(button.dataset.invite); refreshRooms(); toast("Room invitation accepted."); }
    catch (error) { toast(error.message || "Could not accept invite."); }
  }));
  list.querySelectorAll("[data-decline]").forEach((button) => button.addEventListener("click", async () => {
    try { await client.leave(button.dataset.decline); refreshRooms(); toast("Room invitation reddedildi."); }
    catch (error) { toast(error.message || "Could not decline invite."); }
  }));
}

function openRoom(roomId) {
  activeRoomId = roomId;
  unreadCounts.delete(roomId);
  if (typeof window.RedShoeAndroid?.setActiveRoomId === "function") {
    window.RedShoeAndroid.setActiveRoomId(roomId);
  }
  if (typeof window.RedShoeAndroid?.cancelNotification === "function") {
    window.RedShoeAndroid.cancelNotification(roomId);
  }
  const room = client?.getRoom(roomId);
  if (!room) return;
  document.querySelector("#chat-empty").classList.add("hidden");
  document.querySelector("#conversation").classList.remove("hidden");
  setComposerEnabled(true);
  const encrypted = room.hasEncryptionStateEvent();
  const isCellular = typeof window.RedShoeAndroid?.isCellularNetwork === "function" && window.RedShoeAndroid.isCellularNetwork();
  const callButtons = isCellular
    ? `<button class="icon-button call-audio" aria-label="Voice call" title="Voice call (Cellular)">${icon("phone")}</button>`
    : `<button class="icon-button call-audio" aria-label="Voice call" title="Voice call">${icon("phone")}</button><button class="icon-button call-video" aria-label="Video call" title="Video call">${icon("video")}</button>`;

  document.querySelector("#chat-header").innerHTML = `<button class="icon-button back-button" aria-label="Rooms">${icon("back")}</button><div class="avatar header-avatar">${escapeHtml(initials(room.name))}</div><div class="header-copy"><strong>${escapeHtml(room.name || room.roomId)}</strong><span>${encrypted ? `${icon("lock")} End-to-end encrypted` : escapeHtml(room.roomId)}</span></div><div class="header-actions">${callButtons}<button class="icon-button room-info" aria-label="Room invitation" title="Invite to room">${icon("plus")}</button>${returnGameButtonMarkup()}</div>`;
  document.querySelector("#chat-header .back-button").addEventListener("click", () => document.querySelector(".sidebar").classList.add("sidebar-open"));
  bindReturnGameButton();
  document.querySelector(".call-audio")?.addEventListener("click", () => startCall(false));
  document.querySelector(".call-video")?.addEventListener("click", () => startCall(true));
  document.querySelector(".room-info").addEventListener("click", () => inviteToRoom(roomId));
  renderRoomList();
  renderMessages();
  renderPinnedMessages(room);
  const latestEvent = room.getLiveTimeline().getEvents().at(-1);
  if (latestEvent) client.sendReadReceipt(latestEvent).catch(() => {});
  document.querySelector(".sidebar").classList.remove("sidebar-open");
}

function renderMessages() {
  const room = client?.getRoom(activeRoomId);
  const list = document.querySelector("#message-list");
  if (!room || !list) return;
  const timeline = room.getLiveTimeline().getEvents();
  const events = timeline.filter((event) => event.getType() === "m.room.message" && event.getContent()?.body);
  const reactions = new Map();
  for (const event of timeline.filter((item) => item.getType() === "m.reaction")) {
    const relation = event.getContent()?.["m.relates_to"];
    if (relation?.rel_type !== "m.annotation" || !relation.event_id || !relation.key) continue;
    const grouped = reactions.get(relation.event_id) || new Map();
    grouped.set(relation.key, (grouped.get(relation.key) || 0) + 1);
    reactions.set(relation.event_id, grouped);
  }
  const pinned = room.currentState.getStateEvents("m.room.pinned_events", "")?.getContent()?.pinned || [];
  renderPinnedMessages(room, pinned);
  list.innerHTML = events.map((event) => {
    const mine = event.getSender() === client.getUserId();
    const content = event.getContent();
    const date = new Date(event.getTs());
    const eventId = event.getId();
    const relation = content["m.relates_to"]?.["m.in_reply_to"];
    const repliedEvent = relation?.event_id && timeline.find((candidate) => candidate.getId() === relation.event_id);
    const replyMarkup = repliedEvent ? `<div class="reply-quote">${escapeHtml(repliedEvent.getSender())}: ${escapeHtml(repliedEvent.getContent()?.body || "Attachment")}</div>` : "";
    const mediaMarkup = renderMediaMessage(content, eventId);
    const linkPreview = content["com.beeper.linkpreviews"]?.[0];
    const previewMarkup = linkPreview ? `<a class="link-preview" href="${escapeHtml(linkPreview.matched_url || "#")}" target="_blank" rel="noreferrer">${linkPreview["og:image"] ? `<img src="${escapeHtml(client.mxcUrlToHttp(linkPreview["og:image"]) || linkPreview["og:image"])}" alt="" loading="lazy">` : ""}<span><strong>${escapeHtml(linkPreview["og:title"] || linkPreview.matched_url || "Link")}</strong><small>${escapeHtml(linkPreview["og:description"] || "")}</small><em>${escapeHtml(linkPreview.matched_url || "")}</em></span></a>` : "";
    const text = content.body ? `<div class="message-bubble">${escapeHtml(content.body).replace(/\n/g, "<br>")}</div>` : "";
    const reactionMarkup = [...(reactions.get(eventId) || new Map())].map(([emoji, count]) => `<span class="reaction-chip">${escapeHtml(emoji)} ${count}</span>`).join("");
    const state = messageStatus(room, event);
    const status = mine ? `<span class="message-status ${state === "Failed" ? "failed" : ""}">${escapeHtml(state)}</span>` : "";
    const pinLabel = pinned.includes(eventId) ? "Unpin" : "Pin";
    return `<article class="message ${mine ? "mine" : ""} ${pinned.includes(eventId) ? "pinned-message" : ""}" data-event="${escapeHtml(eventId || "")}"><div class="message-meta"><strong>${escapeHtml(mine ? "You" : (room.getMember(event.getSender())?.name || event.getSender()))}</strong><time>${date.toLocaleTimeString("en-US", { hour: "2-digit", minute: "2-digit" })}</time>${status}</div>${replyMarkup}${text}${previewMarkup}${mediaMarkup}<div class="message-actions"><button type="button" data-action="reply" title="Answer" aria-label="Answer">${icon("reply")}</button><button type="button" data-action="react" title="Emoji reaction" aria-label="Emoji reaction">${icon("emoji")}</button><button type="button" data-action="pin" title="${pinLabel}" aria-label="${pinLabel}">${icon("pin")}</button></div><div class="reaction-list">${reactionMarkup}</div><div class="emoji-menu hidden" data-reaction-menu>${["👍", "❤️", "😂", "🎉", "🙏"].map((emoji) => `<button type="button" data-reaction="${emoji}">${emoji}</button>`).join("")}</div></article>`;
  }).join("") + failedMessages.filter((item) => item.roomId === activeRoomId).map((item) => `<article class="message mine failed-message"><div class="message-meta"><strong>You</strong><span class="message-status failed">Failed</span></div><div class="message-bubble">${escapeHtml(item.body)}</div><button type="button" class="retry-message" data-retry="${item.id}">Tekrar dene</button></article>`).join("");
  list.scrollTop = list.scrollHeight;
}

function renderPinnedMessages(room, pinnedIds = null) {
  const strip = document.querySelector("#pinned-strip");
  const items = document.querySelector("#pinned-items");
  if (!strip || !items) return;
  const pinned = pinnedIds || room.currentState.getStateEvents("m.room.pinned_events", "")?.getContent()?.pinned || [];
  if (!pinned.length) {
    strip.classList.add("hidden");
    return;
  }
  strip.classList.remove("hidden");
  strip.querySelector(".pinned-count").textContent = String(pinned.length);
  items.innerHTML = pinned.map((eventId) => {
    const event = room.getLiveTimeline().getEvents().find((item) => item.getId() === eventId);
    const body = event?.getContent()?.body || "Open pinned message";
    const sender = event?.getSender() || "Matrix message";
    return `<button type="button" class="pinned-item" data-pinned-event="${escapeHtml(eventId)}"><span class="pin-mark">⌁</span><span><strong>${escapeHtml(sender)}</strong><small>${escapeHtml(body)}</small></span><span class="pinned-arrow">↗</span></button>`;
  }).join("");
  items.querySelectorAll("[data-pinned-event]").forEach((button) => button.addEventListener("click", () => {
    document.querySelector(`[data-event="${CSS.escape(button.dataset.pinnedEvent)}"]`)?.scrollIntoView({ behavior: "smooth", block: "center" });
    document.querySelector("#pinned-items").classList.add("hidden");
    document.querySelector(".pinned-toggle").setAttribute("aria-expanded", "false");
  }));
}

function togglePinnedList() {
  const items = document.querySelector("#pinned-items");
  const expanded = document.querySelector(".pinned-toggle").getAttribute("aria-expanded") === "true";
  items.classList.toggle("hidden", expanded);
  document.querySelector(".pinned-toggle").setAttribute("aria-expanded", String(!expanded));
}

function detectMessageType(file, forcedType = null) {
  if (forcedType) return forcedType;
  const mime = (file.type || "").toLowerCase();
  if (mime.startsWith("image/")) return "m.image";
  if (mime.startsWith("audio/")) return "m.audio";
  if (mime.startsWith("video/")) return "m.video";

  const ext = (file.name || "").split('.').pop()?.toLowerCase();
  if (["jpg", "jpeg", "png", "gif", "webp", "bmp", "svg"].includes(ext)) return "m.image";
  if (["mp3", "ogg", "wav", "m4a", "aac", "webm", "flac"].includes(ext)) return "m.audio";
  if (["mp4", "mkv", "mov", "avi", "webm", "3gp"].includes(ext)) return "m.video";

  return "m.file";
}

function renderMediaMessage(content, eventId) {
  if (!content.msgtype) return "";
  const label = content.body || "Media";
  const mxcUrl = content.url || content.file?.url;

  if (content.msgtype === "m.image") {
    const httpUrl = mxcUrl ? client?.mxcUrlToHttp(mxcUrl, 600, 600, "scale") : null;
    const isEncrypted = !!content.file;
    const imgMarkup = httpUrl && !isEncrypted
      ? `<img src="${escapeHtml(httpUrl)}" alt="${escapeHtml(label)}" class="inline-chat-img" loading="lazy">`
      : `<button type="button" class="media-thumb encrypted-thumb" data-preview-media="${escapeHtml(eventId)}"><span class="media-placeholder">${icon("image")} Open / zoom photo</span></button>`;
    return `<div class="media-preview media-card"><button type="button" class="media-thumb" data-preview-media="${escapeHtml(eventId)}" aria-label="Zoom in">${imgMarkup}</button><span class="media-name">${escapeHtml(label)}</span><div class="media-actions"><button type="button" data-preview-media="${escapeHtml(eventId)}" title="Zoom in">View</button><button type="button" data-open-attachment="${escapeHtml(eventId)}" title="Download">${icon("download")} Download</button></div></div>`;
  }

  if (content.msgtype === "m.video") {
    const httpUrl = mxcUrl ? client?.mxcUrlToHttp(mxcUrl) : null;
    const isEncrypted = !!content.file;
    const videoMarkup = httpUrl && !isEncrypted
      ? `<video src="${escapeHtml(httpUrl)}" controls playsinline preload="metadata" class="inline-chat-video"></video>`
      : `<button type="button" class="media-thumb" data-preview-media="${escapeHtml(eventId)}"><span class="video-play">▶</span><span class="video-label">${escapeHtml(label)}</span></button>`;
    return `<div class="media-preview media-card video-card">${videoMarkup}<span class="media-name">${escapeHtml(label)}</span><div class="media-actions"><button type="button" data-preview-media="${escapeHtml(eventId)}" title="Tam ekran">Oynat / Tam Ekran</button><button type="button" data-open-attachment="${escapeHtml(eventId)}" title="Download">${icon("download")} Download</button></div></div>`;
  }

  if (content.msgtype === "m.audio") {
    const httpUrl = mxcUrl ? client?.mxcUrlToHttp(mxcUrl) : null;
    const isEncrypted = !!content.file;
    const audioMarkup = httpUrl && !isEncrypted
      ? `<audio src="${escapeHtml(httpUrl)}" controls class="inline-chat-audio"></audio>`
      : `<button type="button" class="attachment-download" data-preview-media="${escapeHtml(eventId)}">🎵 <span>${escapeHtml(label)} (Dinle)</span></button>`;
    return `<div class="media-preview media-card audio-card">${audioMarkup}<div class="media-actions"><button type="button" data-open-attachment="${escapeHtml(eventId)}" title="Download">${icon("download")} Download</button></div></div>`;
  }

  if (content.msgtype === "m.location") {
    const geoUri = content.geo_uri || content.body || "";
    const match = geoUri.match(/geo:(-?\d+\.\d+),(-?\d+\.\d+)/) || content.body?.match(/(-?\d+\.\d+),\s*(-?\d+\.\d+)/);
    if (match) {
      const lat = match[1];
      const lng = match[2];
      const mapUrl = `https://www.google.com/maps?q=${lat},${lng}`;
      return `<div class="media-card location-card"><div class="location-header">📍 <strong>Shared location</strong></div><span class="location-coords">${lat}, ${lng}</span><a class="location-btn" href="${mapUrl}" target="_blank" rel="noreferrer">🗺️ Open in Maps</a></div>`;
    }
  }

  if (content.msgtype !== "m.file" || !mxcUrl) return "";
  return `<button type="button" class="attachment-download" data-open-attachment="${escapeHtml(eventId)}">${icon("download")}<span>${escapeHtml(label)}</span></button>`;
}

function messageStatus(room, event) {
  const eventId = event.getId();
  const sendState = sentStates.get(eventId) || event.status;
  if (["not_sent", "sending_failed", "cancelled", "NOT_SENT", "SENDING_FAILED", "CANCELLED"].includes(sendState)) return "Failed";
  if (["sending", "queued", "encrypting", "SENDING", "QUEUED", "ENCRYPTING"].includes(sendState)) return "Sending...";
  const recipients = room.getMembers().filter((member) => member.membership === "join" && member.userId !== client.getUserId());
  if (recipients.length && eventId && recipients.every((member) => room.hasUserReadEvent(member.userId, eventId))) return "Okundu";
  return "Delivered";
}

async function sendMessage(event) {
  event.preventDefault();
  const input = event.currentTarget.elements.message;
  let body = input.value.trim();
  if (!body || !activeRoomId) return;
  const roomId = activeRoomId;
  const target = replyTarget;
  if (target) body = `> ${target.sender}: ${target.body}\n\n${body}`;
  const content = { msgtype: "m.text", body };
  if (target) content["m.relates_to"] = { "m.in_reply_to": { event_id: target.eventId } };
  const url = input.value.match(/https?:\/\/[^\s<>]+/i)?.[0];
  input.disabled = true;
  try {
    if (url) {
      try {
        const preview = await client.getUrlPreview(url, Date.now());
        if (preview && (preview["og:title"] || preview["og:description"])) {
          content["com.beeper.linkpreviews"] = [{ matched_url: url, ...preview }];
        } else {
          content["com.beeper.linkpreviews"] = [{ matched_url: url, "og:title": new URL(url).hostname, "og:description": url }];
        }
      } catch (error) {
        try {
          content["com.beeper.linkpreviews"] = [{ matched_url: url, "og:title": new URL(url).hostname, "og:description": url }];
        } catch (e) {}
      }
    }
    const response = await client.sendEvent(roomId, "m.room.message", content);
    sentStates.set(response.event_id, "sent");
    input.value = "";
    clearReplyTarget();
    renderMessages();
  } catch (error) {
    failedMessages.push({ id: crypto.randomUUID(), roomId, body: input.value.trim() });
    toast(error.message || "Could not send message.");
    renderMessages();
  } finally {
    input.disabled = false;
    input.focus();
  }
}

async function sendAttachment(file, forcedType = null) {
  const room = client?.getRoom(activeRoomId);
  if (!room || !file) return;
  toast("Uploading file...");
  try {
    const type = detectMessageType(file, forcedType);
    const bytes = await file.arrayBuffer();
    const encrypted = room.hasEncryptionStateEvent();
    const attachment = encrypted ? await encryptAttachment(bytes) : { data: bytes, info: null };
    const uploadBlob = new Blob([attachment.data], { type: file.type || "application/octet-stream" });
    const uploaded = await client.uploadContent(uploadBlob, { name: file.name, type: file.type || "application/octet-stream", includeFilename: true });
    const content = {
      msgtype: type,
      body: file.name || (type === "m.audio" ? "Voice message" : "Media"),
      info: { mimetype: file.type || (type === "m.image" ? "image/jpeg" : type === "m.audio" ? "audio/webm" : type === "m.video" ? "video/mp4" : "application/octet-stream"), size: file.size },
    };
    if (encrypted) content.file = { ...attachment.info, url: uploaded.content_uri };
    else content.url = uploaded.content_uri;
    const response = await client.sendEvent(room.roomId, "m.room.message", content);
    sentStates.set(response.event_id, "sent");
    renderMessages();
    toast("File sent.");
  } catch (error) {
    failedMessages.push({ id: crypto.randomUUID(), roomId: room.roomId, body: file.name || "Voice message", file, forcedType });
    renderMessages();
    toast(error.message || "Could not send file.");
  }
}

async function openAttachment(eventId, { preview = false } = {}) {
  const room = client?.getRoom(activeRoomId);
  const event = room?.getLiveTimeline().getEvents().find((item) => item.getId() === eventId);
  const content = event?.getContent();
  const mxcUrl = content?.file?.url || content?.url;
  const httpUrl = mxcUrl && client.mxcUrlToHttp(mxcUrl, undefined, undefined, undefined, false, undefined, true);
  if (!content || !httpUrl) return;
  try {
    toast(preview ? "Preparing media..." : "Downloading file...");
    const session = JSON.parse(localStorage.getItem(SESSION_KEY) || localStorage.getItem(LEGACY_SESSION_KEY) || "null");
    const response = await fetch(httpUrl, { headers: { Authorization: `Bearer ${session?.accessToken || ""}` } });
    if (!response.ok) throw new Error("Could not download file.");
    let bytes = await response.arrayBuffer();
    if (content.file) bytes = await decryptAttachment(bytes, content.file);
    const mimeType = content.info?.mimetype || "application/octet-stream";
    const fileName = content.body || "redshoe-file";

    if (preview && ["m.image", "m.video", "m.audio"].includes(content.msgtype)) {
      const blob = new Blob([bytes], { type: mimeType });
      const objectUrl = URL.createObjectURL(blob);
      showMediaViewer(objectUrl, content);
    } else {
      if (typeof window.RedShoeAndroid?.downloadFile === "function") {
        const base64 = arrayBufferToBase64(bytes);
        window.RedShoeAndroid.downloadFile(base64, fileName, mimeType);
      } else {
        const blob = new Blob([bytes], { type: mimeType });
        const objectUrl = URL.createObjectURL(blob);
        const anchor = document.createElement("a");
        anchor.href = objectUrl;
        anchor.download = fileName;
        anchor.click();
        setTimeout(() => URL.revokeObjectURL(objectUrl), 30000);
        toast("Download complete.");
      }
    }
  } catch (error) { toast(error.message || "Could not open attachment."); }
}

function arrayBufferToBase64(buffer) {
  let binary = "";
  const bytes = new Uint8Array(buffer);
  const len = bytes.byteLength;
  for (let i = 0; i < len; i++) {
    binary += String.fromCharCode(bytes[i]);
  }
  return window.btoa(binary);
}

function showMediaViewer(objectUrl, content) {
  const root = document.querySelector("#modal-root");
  const isVideo = content.msgtype === "m.video";
  const isAudio = content.msgtype === "m.audio";
  root.innerHTML = `<div class="media-viewer-backdrop"><section class="media-viewer" role="dialog" aria-modal="true" aria-label="${escapeHtml(content.body || "Media preview")}"><header class="media-viewer-toolbar"><strong>${escapeHtml(content.body || "Media")}</strong><div class="media-viewer-actions">${isVideo || isAudio ? "" : '<button type="button" data-zoom="out" aria-label="Zoom out" title="Zoom out">−</button><button type="button" data-zoom="reset" aria-label="Reset zoom" title="Reset zoom">100%</button><button type="button" data-zoom="in" aria-label="Zoom in" title="Zoom in">+</button>'}<button type="button" data-media-download title="Download">${icon("download")}</button><button type="button" data-media-close aria-label="Close" title="Close">${icon("close")}</button></div></header><div class="media-viewer-stage">${isVideo ? `<video src="${objectUrl}" controls autoplay playsinline></video>` : isAudio ? `<audio src="${objectUrl}" controls autoplay></audio>` : `<img src="${objectUrl}" alt="${escapeHtml(content.body || "Photo")}">`}</div></section></div>`;
  const close = () => {
    root.innerHTML = "";
    URL.revokeObjectURL(objectUrl);
  };
  root.querySelector("[data-media-close]").addEventListener("click", close);
  root.querySelector(".media-viewer-backdrop").addEventListener("click", (event) => {
    if (event.target.classList.contains("media-viewer-backdrop")) close();
  });
  root.querySelector("[data-media-download]").addEventListener("click", () => {
    const anchor = document.createElement("a");
    anchor.href = objectUrl;
    anchor.download = content.body || "redshoe-media";
    anchor.click();
  });
  if (!isVideo && !isAudio) {
    const image = root.querySelector(".media-viewer-stage img");
    let zoom = 1;
    const applyZoom = () => { image.style.transform = `scale(${zoom})`; };
    root.querySelectorAll("[data-zoom]").forEach((button) => button.addEventListener("click", () => {
      if (button.dataset.zoom === "in") zoom = Math.min(zoom + 0.3, 5);
      else if (button.dataset.zoom === "out") zoom = Math.max(zoom - 0.3, 0.5);
      else zoom = 1;
      applyZoom();
    }));
    image.addEventListener("wheel", (event) => {
      event.preventDefault();
      zoom = Math.max(0.5, Math.min(5, zoom + (event.deltaY < 0 ? 0.2 : -0.2)));
      applyZoom();
    }, { passive: false });

    let startDist = 0;
    let baseZoom = 1;
    const stage = root.querySelector(".media-viewer-stage");
    if (stage && image) {
      stage.addEventListener("touchstart", (e) => {
        if (e.touches.length === 2) {
          startDist = Math.hypot(
            e.touches[0].clientX - e.touches[1].clientX,
            e.touches[0].clientY - e.touches[1].clientY
          );
          baseZoom = zoom;
        }
      });
      stage.addEventListener("touchmove", (e) => {
        if (e.touches.length === 2 && startDist > 0) {
          e.preventDefault();
          const currentDist = Math.hypot(
            e.touches[0].clientX - e.touches[1].clientX,
            e.touches[0].clientY - e.touches[1].clientY
          );
          zoom = Math.min(Math.max(0.5, baseZoom * (currentDist / startDist)), 5);
          applyZoom();
        }
      }, { passive: false });
    }
  }
}

async function toggleVoiceRecording(event) {
  const button = event.currentTarget;
  if (recording) {
    recording.recorder.stop();
    button.classList.remove("recording");
    button.title = "Record voice message";
    document.querySelector("#composer-mode-label").textContent = "SENDING VOICE MESSAGE";
    document.querySelector("#voice-mode-hint").textContent = "Recording complete · uploading";
    return;
  }
  try {
    const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
    const recorder = new MediaRecorder(stream);
    const chunks = [];
    recording = { recorder, stream, chunks };
    recorder.addEventListener("dataavailable", (mediaEvent) => { if (mediaEvent.data.size) chunks.push(mediaEvent.data); });
    recorder.addEventListener("stop", async () => {
      const blob = new Blob(chunks, { type: recorder.mimeType || "audio/webm" });
      stream.getTracks().forEach((track) => track.stop());
      recording = null;
      if (blob.size) await sendAttachment(new File([blob], `voice-${Date.now()}.webm`, { type: blob.type }), "m.audio");
      document.querySelector("#composer-mode-label").textContent = "WRITE A MESSAGE";
      document.querySelector("#voice-mode-hint").textContent = "Tap the microphone icon; tap again to stop";
    }, { once: true });
    recorder.start();
    button.classList.add("recording");
    button.title = "Finish and send recording";
    document.querySelector("#composer-mode-label").textContent = "VOICE RECORDING ACTIVE";
    document.querySelector("#voice-mode-hint").textContent = "Recording... Tap the microphone to finish and send";
  } catch (error) { toast(error.message || "Could not access microphone."); }
}

function clearReplyTarget() {
  replyTarget = null;
  document.querySelector("#reply-banner")?.classList.add("hidden");
}

async function handleMessageAction(event) {
  const button = event.target.closest("button[data-action],button[data-reaction],button[data-preview-media],button[data-open-attachment],button[data-retry]");
  if (!button) return;
  if (button.dataset.previewMedia) return openAttachment(button.dataset.previewMedia, { preview: true });
  if (button.dataset.openAttachment) return openAttachment(button.dataset.openAttachment);
  if (button.dataset.retry) {
    const failed = failedMessages.find((message) => message.id === button.dataset.retry);
    if (failed) {
      failedMessages.splice(failedMessages.indexOf(failed), 1);
      renderMessages();
      if (failed.file) sendAttachment(failed.file, failed.forcedType);
      else {
        const input = document.querySelector("#composer").elements.message;
        input.value = failed.body;
        input.focus();
      }
    }
    return;
  }
  const article = button.closest("[data-event]");
  const eventId = article?.dataset.event;
  if (!eventId) return;
  if (button.dataset.reaction) {
    const emoji = button.dataset.reaction;
    try { await client.sendEvent(activeRoomId, "m.reaction", { "m.relates_to": { rel_type: "m.annotation", event_id: eventId, key: emoji } }); }
    catch (error) { toast(error.message || "Could not send reaction."); }
  } else if (button.dataset.action === "reply") {
    const original = client.getRoom(activeRoomId)?.getLiveTimeline().getEvents().find((item) => item.getId() === eventId);
    replyTarget = { eventId, sender: original?.getSender() || "", body: original?.getContent()?.body || "Attachment" };
    document.querySelector("#reply-label").textContent = `Reply: ${replyTarget.sender} · ${replyTarget.body}`;
    document.querySelector("#reply-banner").classList.remove("hidden");
    document.querySelector("#composer [name=message]").focus();
  } else if (button.dataset.action === "react") {
    const menu = article.querySelector("[data-reaction-menu]");
    menu.classList.toggle("hidden");
  } else if (button.dataset.action === "pin") {
    const room = client.getRoom(activeRoomId);
    const pinned = room.currentState.getStateEvents("m.room.pinned_events", "")?.getContent()?.pinned || [];
    const nextPinned = pinned.includes(eventId) ? pinned.filter((id) => id !== eventId) : [...pinned, eventId];
    try {
      await client.sendStateEvent(activeRoomId, "m.room.pinned_events", { pinned: nextPinned }, "");
      renderMessages();
      toast(nextPinned.includes(eventId) ? "Message pinned." : "Message unpinned.");
    } catch (error) { toast(error.message || "Could not pin message."); }
  }
}

function showAddMenu() {
  showModal("New conversation", `<button class="action-row" data-action="create-room"><span class="action-icon">#</span><span><strong>Create room</strong><small>Optional end-to-end encryption</small></span><b>→</b></button><button class="action-row" data-action="join-room"><span class="action-icon">↗</span><span><strong>Join room</strong><small>with a room ID or alias</small></span><b>→</b></button><button class="action-row" data-action="direct-chat"><span class="action-icon">@</span><span><strong>Direct message</strong><small>with a Matrix user ID</small></span><b>→</b></button>`);
  document.querySelector('[data-action="create-room"]').addEventListener("click", createRoomDialog);
  document.querySelector('[data-action="join-room"]').addEventListener("click", joinRoomDialog);
  document.querySelector('[data-action="direct-chat"]').addEventListener("click", directChatDialog);
}

function createRoomDialog() {
  showModal("Create room", `<form id="create-room-form" class="modal-form"><label>Room name<input name="name" required maxlength="80" placeholder="e.g. Design team"></label><label class="check-row"><input name="encrypted" type="checkbox" checked><span>End-to-end encryption</span>${icon("lock")}</label><p class="form-hint">The encryption setting cannot be changed after the room is created.</p><button class="primary-button">Create room <span>→</span></button></form>`);
  document.querySelector("#create-room-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    const form = new FormData(event.currentTarget);
    const encrypted = form.has("encrypted");
    try {
      const result = await client.createRoom({ name: form.get("name").trim(), visibility: "private", preset: "private_chat", initial_state: encrypted ? [{ type: "m.room.encryption", state_key: "", content: { algorithm: "m.megolm.v1.aes-sha2" } }] : [] });
      closeModal();
      await waitForRoom(result.room_id);
      refreshRooms();
      openRoom(result.room_id);
      toast(encrypted ? "Encrypted room created." : "Room created.");
    } catch (error) { toast(error.message || "Could not create room."); }
  });
}

function joinRoomDialog() {
  showModal("Join room", `<form id="join-room-form" class="modal-form"><label>Room ID or alias<input name="room" required placeholder="#chat:matrix.org"></label><button class="primary-button">Join <span>→</span></button></form>`);
  document.querySelector("#join-room-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    try {
      const result = await client.joinRoom(event.currentTarget.elements.room.value.trim());
      closeModal(); refreshRooms(); openRoom(result.roomId); toast("You joined the room.");
    } catch (error) { toast(error.message || "Could not join room."); }
  });
}

function directChatDialog() {
  showModal("Direct message", `<form id="direct-form" class="modal-form"><label>Person's Matrix ID<input name="user" required placeholder="@ada:matrix.org"></label><p class="form-hint">New direct messages are end-to-end encrypted.</p><button class="primary-button">Open chat <span>→</span></button></form>`);
  document.querySelector("#direct-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    const userId = event.currentTarget.elements.user.value.trim();
    try {
      const result = await client.createRoom({ preset: "trusted_private_chat", visibility: "private", invite: [userId], is_direct: true, name: userId, initial_state: [{ type: "m.room.encryption", state_key: "", content: { algorithm: "m.megolm.v1.aes-sha2" } }] });
      closeModal();
      await waitForRoom(result.room_id);
      refreshRooms(); openRoom(result.room_id); toast("Encrypted direct message created.");
    } catch (error) { toast(error.message || "Could not open direct message."); }
  });
}

async function inviteToRoom(roomId) {
  const userId = prompt("Matrix user ID to invite", "@user:matrix.org");
  if (!userId) return;
  try { await client.invite(roomId, userId.trim()); toast(`${userId} was invited.`); }
  catch (error) { toast(error.message || "Could not send invite."); }
}

function showSettings() {
  const ownUser = client.getUser(client.getUserId());
  const notifications = localStorage.getItem(NOTIFICATIONS_KEY) === "true";
  showModal("Settings", `<div class="settings-content"><div class="settings-line"><span>Account</span><strong>${escapeHtml(client.getUserId())}</strong></div><form class="modal-form" id="profile-form"><label>Display name<input name="displayName" maxlength="64" value="${escapeHtml(ownUser?.displayName || "")}" placeholder="Display name"></label><button class="secondary-button">Save display name</button></form><label class="check-row notification-setting"><input type="checkbox" ${notifications ? "checked" : ""}><span>Desktop notifications</span></label><div class="settings-line"><span>Homeserver</span><strong>${escapeHtml(JSON.parse(localStorage.getItem(SESSION_KEY)).baseUrl)}</strong></div><div class="settings-line"><span>Device</span><strong>${escapeHtml(client.getDeviceId() || "This device")}</strong></div><div class="settings-line"><span>Encryption</span><strong>Matrix Rust Crypto</strong></div><button class="secondary-button leave-room-button">Leave selected room</button><button class="secondary-button danger logout-modal">Log out</button></div>`);
  document.querySelector("#profile-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    try {
      const name = event.currentTarget.elements.displayName.value.trim();
      await client.setDisplayName(name);
      document.querySelector(".profile-copy strong").textContent = name || client.getUserId().split(":")[0].slice(1);
      toast("Display name updated.");
    } catch (error) { toast(error.message || "Could not update display name."); }
  });
  document.querySelector(".notification-setting input").addEventListener("change", async (event) => {
    if (!("Notification" in window)) {
      event.target.checked = false;
      toast("This WebView does not support notifications.");
      return;
    }
    let permission = Notification.permission;
    if (event.target.checked && permission === "default") permission = await Notification.requestPermission();
    const enabled = event.target.checked && permission === "granted";
    event.target.checked = enabled;
    localStorage.setItem(NOTIFICATIONS_KEY, String(enabled));
    if (!enabled && permission !== "granted") toast("Notification permission was not granted.");
  });
  document.querySelector(".leave-room-button").addEventListener("click", async () => {
    if (!activeRoomId) return toast("Select a room first.");
    try { await client.leave(activeRoomId); activeRoomId = null; setComposerEnabled(false); closeModal(); refreshRooms(); document.querySelector("#conversation").classList.add("hidden"); document.querySelector("#chat-empty").classList.remove("hidden"); toast("You left the room."); }
    catch (error) { toast(error.message || "Could not leave the room."); }
  });
  document.querySelector(".logout-modal").addEventListener("click", logout);
}

function showModal(title, body) {
  const root = document.querySelector("#modal-root");
  root.innerHTML = `<div class="modal-backdrop"><section class="modal" role="dialog" aria-modal="true" aria-label="${escapeHtml(title)}"><header><h2>${escapeHtml(title)}</h2><button class="icon-button modal-close" aria-label="Close">${icon("close")}</button></header><div class="modal-body">${body}</div></section></div>`;
  root.querySelector(".modal-backdrop").addEventListener("click", (event) => { if (event.target.classList.contains("modal-backdrop")) closeModal(); });
  root.querySelector(".modal-close").addEventListener("click", closeModal);
  root.querySelector("input")?.focus();
}

function closeModal() { document.querySelector("#modal-root").innerHTML = ""; }
function toast(message) {
  const element = document.querySelector("#toast");
  if (!element) return;
  element.textContent = message;
  element.classList.add("visible");
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => element.classList.remove("visible"), 3200);
}

async function waitForRoom(roomId) {
  if (client.getRoom(roomId)) return;
  await new Promise((resolve) => {
    const timeout = setTimeout(() => { client.removeListener("Room", onRoom); resolve(); }, 6000);
    function onRoom(room) {
      if (room.roomId === roomId) { clearTimeout(timeout); client.removeListener("Room", onRoom); resolve(); }
    }
    client.on("Room", onRoom);
  });
}

function notifyRoom(room, event) {
  if (room.roomId === activeRoomId) return;
  const body = event.getContent()?.body || "New message";
  if (notifyNative(room.name || "PurpleShoe", body, room.roomId, "message")) return;
  if (!("Notification" in window) || localStorage.getItem(NOTIFICATIONS_KEY) !== "true" || Notification.permission !== "granted") return;
  const notification = new Notification(room.name || "PurpleShoe", { body });
  notification.onclick = () => { window.focus(); openRoom(room.roomId); notification.close(); };
}

function notifyNative(title, body, roomId = "", kind = "message") {
  if (typeof window.RedShoeAndroid?.showNotification !== "function") return false;
  try { window.RedShoeAndroid.showNotification(title, body, roomId, kind); return true; }
  catch (error) { console.warn("Android notification bridge failed", error); return false; }
}

async function handleAndroidLaunch() {
  if (typeof window.RedShoeAndroid?.consumeLaunchData !== "function") return;
  try {
    const launchData = window.RedShoeAndroid.consumeLaunchData();
    if (!launchData) return;
    const [roomId, kind] = launchData.split("\n");
    if (!roomId) return;
    await waitForRoom(roomId);
    openRoom(roomId);
    if (kind === "call" && call?.roomId === roomId) return;
    toast(kind === "call" ? "Call room opened." : "Message room opened.");
  } catch (error) { toast(error.message || "Could not open notification room."); }
}

async function logout() {
  const session = JSON.parse(localStorage.getItem(SESSION_KEY) || "null");
  try { await client?.stopClient(); } catch {}
  if (session) {
    try { await fetch(`${session.baseUrl}/_matrix/client/v3/logout`, { method: "POST", headers: { Authorization: `Bearer ${session.accessToken}` } }); } catch {}
  }
  localStorage.removeItem(SESSION_KEY);
  localStorage.removeItem(LEGACY_SESSION_KEY);
  location.reload();
}

function callEvent(type, content) {
  return client.sendEvent(call.roomId, type, content);
}

async function startCall(video) {
  if (!activeRoomId || call) return;
  const isCellular = typeof window.RedShoeAndroid?.isCellularNetwork === "function" && window.RedShoeAndroid.isCellularNetwork();

  if (isCellular) {
    if (typeof window.RedShoeAndroid?.initiateNativeSocketCall === "function") {
      const room = client?.getRoom(activeRoomId);
      const peer = room ? (room.getMembers().find((m) => m.userId !== client.getUserId())?.userId || activeRoomId) : activeRoomId;
      window.RedShoeAndroid.initiateNativeSocketCall(peer);
      showCallUI("Cellular call in progress...");
      return;
    }
  }

  if (typeof window.RedShoeAndroid?.requestMediaPermissions === "function") {
    window.RedShoeAndroid.requestMediaPermissions();
  }
  const room = client?.getRoom(activeRoomId);
  if (room && room.getJoinedMemberCount() > 2) return startGroupCall(video, activeRoomId);
  try {
    const matrixCall = client.createCall(activeRoomId);
    if (!matrixCall) throw new Error("Could not start WebRTC calls.");
    attachDirectCall(matrixCall, false);
    await (video ? matrixCall.placeVideoCall() : matrixCall.placeVoiceCall());
    showCallUI("Calling...");
  } catch (error) { endCall(false); toast(error.message || "Could not start call. Check camera and microphone permissions."); }
}

function attachDirectCall(matrixCall, incoming) {
  const member = matrixCall.getOpponentMember();
  call = { mode: "direct", roomId: matrixCall.roomId, sdkCall: matrixCall, video: matrixCall.type === "video", incoming, caller: member?.name || matrixCall.invitee || "Matrix user" };
  matrixCall.on(CallEvent.State, (state) => {
    if (state === "connected") setCallStatus("Connected");
    else if (state === "connecting") setCallStatus("Connecting...");
    else if (state === "ended") endCall(false);
  });
  matrixCall.on(CallEvent.FeedsChanged, renderCallFeeds);
  matrixCall.on(CallEvent.Hangup, () => endCall(false));
  matrixCall.on(CallEvent.Error, (error) => toast(error.message || "An error occurred during the call."));
}

function receiveCall(matrixCall) {
  if (call) {
    matrixCall.reject();
    return;
  }
  attachDirectCall(matrixCall, true);
  notifyNative("Incoming call", call.caller, call.roomId, "call");
  showIncomingCall(call.caller, call.video);
}

async function startGroupCall(video, roomId) {
  try {
    await client.waitUntilRoomReadyForGroupCalls(roomId);
    let groupCall = client.getGroupCallForRoom(roomId);
    if (!groupCall) groupCall = await client.createGroupCall(roomId, video ? GroupCallType.Video : GroupCallType.Voice, false, GroupCallIntent.Room);
    call = { mode: "group", roomId, groupCall, video, incoming: false };
    groupCall.on(GroupCallEvent.UserMediaFeedsChanged, renderCallFeeds);
    groupCall.on(GroupCallEvent.ParticipantsChanged, renderCallFeeds);
    groupCall.on(GroupCallEvent.GroupCallStateChanged, (state) => setCallStatus(state === "entered" ? "Connected" : "Connecting..."));
    groupCall.on(GroupCallEvent.Error, (error) => toast(error.message || "An error occurred during the conference."));
    showCallUI("Connecting to conference...");
    await groupCall.enter();
    setCallStatus("Connected");
    renderCallFeeds();
  } catch (error) { endCall(false); toast(error.message || "Could not start conference. Check that the server supports MatrixRTC."); }
}

function receiveGroupCall(groupCall) {
  const roomId = groupCall.room.roomId;
  if (call) return;
  call = { mode: "group", roomId, groupCall, video: groupCall.type === GroupCallType.Video, incoming: true };
  notifyNative("Conference call", client.getRoom(roomId)?.name || "Room conference", roomId, "call");
  showIncomingCall(client.getRoom(roomId)?.name || "Room conference", call.video, true);
}

function showIncomingCall(sender, video, group = false) {
  const layer = document.querySelector("#call-layer");
  layer.innerHTML = `<section class="incoming-call"><div class="incoming-mark">${video ? icon("video") : icon("phone")}</div><strong>${escapeHtml(sender)}</strong><span>${group ? "Join conference" : `Incoming ${video ? "video " : "voice "}call`}</span><div class="incoming-actions"><button class="answer-call">${group ? "Join" : "Answer"}</button><button class="reject-call">${group ? "Close" : "Decline"}</button></div></section>`;
  layer.classList.remove("hidden");
  layer.querySelector(".answer-call").addEventListener("click", answerCall);
  layer.querySelector(".reject-call").addEventListener("click", () => {
    if (call?.mode === "direct") call.sdkCall.reject();
    endCall(false);
  });
}

async function answerCall() {
  if (!call) return;
  try {
    if (call.mode === "group") {
      const groupCall = call.groupCall;
      groupCall.on(GroupCallEvent.UserMediaFeedsChanged, renderCallFeeds);
      groupCall.on(GroupCallEvent.ParticipantsChanged, renderCallFeeds);
      showCallUI("Connecting to conference...");
      await groupCall.enter();
    } else {
      await call.sdkCall.answer(true, call.video);
      showCallUI("Connecting...");
    }
    renderCallFeeds();
  } catch (error) { endCall(true); toast(error.message || "Could not answer call."); }
}

function showCallUI(status) {
  const layer = document.querySelector("#call-layer");
  const title = client.getRoom(call.roomId)?.name || call.caller || "PurpleShoe call";
  layer.innerHTML = `<section class="call-panel ${call.video ? "video-call" : "audio-call"}"><div class="call-media-grid" id="call-media-grid"></div><div class="call-overlay"><div class="call-pulse">${icon(call.video ? "video" : "phone")}</div><strong>${escapeHtml(title)}</strong><span class="call-status">${escapeHtml(status)}</span><div class="call-controls"><button class="toggle-mic" aria-label="Mute microphone">Microphone</button><button class="hangup-call" aria-label="End call">${icon("phone")}</button></div></div></section>`;
  layer.classList.remove("hidden");
  layer.querySelector(".toggle-mic").addEventListener("click", toggleCallMicrophone);
  layer.querySelector(".hangup-call").addEventListener("click", () => endCall(true));
  renderCallFeeds();
}

function renderCallFeeds() {
  if (!call || document.querySelector("#call-media-grid") == null) return;
  const feeds = call.mode === "group" ? call.groupCall.userMediaFeeds : call.sdkCall.getFeeds();
  const grid = document.querySelector("#call-media-grid");
  grid.innerHTML = feeds.map((feed, index) => {
    const local = feed.isLocal();
    const hasVideo = feed.stream.getVideoTracks().some((track) => track.readyState === "live");
    const element = hasVideo ? "video" : "audio";
    const name = local ? "You" : (feed.getMember()?.name || feed.userId);
    return `<div class="call-feed ${local ? "local-feed" : ""}">${hasVideo ? `<${element} data-feed="${index}" autoplay playsinline ${local ? "muted" : ""}></${element}>` : `<${element} data-feed="${index}" autoplay ${local ? "muted" : ""}></${element}>`}<span>${escapeHtml(name)}</span></div>`;
  }).join("");
  feeds.forEach((feed, index) => {
    const media = grid.querySelector(`[data-feed="${index}"]`);
    if (media) { media.srcObject = feed.stream; media.play().catch(() => {}); }
  });
}

function setCallStatus(status) {
  const label = document.querySelector(".call-status");
  if (label) label.textContent = status;
}

async function toggleCallMicrophone(event) {
  if (!call) return;
  const button = event.currentTarget;
  try {
    let muted;
    if (call.mode === "group") muted = await call.groupCall.setMicrophoneMuted(!call.groupCall.isMicrophoneMuted());
    else {
      const track = call.sdkCall.localUsermediaStream?.getAudioTracks()[0];
      if (!track) return;
      track.enabled = !track.enabled;
      muted = !track.enabled;
    }
    button.textContent = muted ? "Unmute microphone" : "Mute microphone";
  } catch (error) { toast(error.message || "Could not toggle microphone."); }
}

async function endCall(notify) {
  if (!call) return;
  const ending = call;
  call = null;
  if (ending.mode === "group") ending.groupCall.leave();
  else if (ending.sdkCall.state !== "ended") ending.sdkCall.hangup("user_hangup", !notify);
  const layer = document.querySelector("#call-layer");
  if (layer) { layer.classList.add("hidden"); layer.innerHTML = ""; }
}

async function initializeApp() {
  if (MATRIX_HANDOFF_TICKET) {
    app.innerHTML = '<main class="handoff-loading" role="status"><div class="loading-mark">P.</div><p>Securely transferring Matrix session...</p></main>';
    try {
      await connect(await redeemMatrixHandoff(MATRIX_HANDOFF_TICKET));
    } catch (error) {
      localStorage.removeItem(SESSION_KEY);
      showLogin(error.message || "Could not open Matrix session.");
    }
    return;
  }
  if (saved?.accessToken && saved?.userId) connect(saved).catch((error) => showLogin(error.message));
  else showLogin();
}

initializeApp();