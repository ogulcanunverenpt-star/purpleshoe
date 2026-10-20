# PurpleShoe

A lightweight, fast Matrix client built with vanilla JS and Vite. No framework overhead.

## Features

- Multi-account support
- Spaces and DMs
- End-to-end encryption status
- Emoji reactions (Emoji 17.0)
- File attachments
- Reply threading
- Member profiles
- Typing indicators
- Mention autocomplete (@user)
- Message deletion (redaction)
- Desktop notifications with sound
- Persistent settings (appearance, notifications, privacy)

## Settings

### Appearance
- Compact message layout
- Member list visibility
- Accent colour theme (purple, blue, green, orange, red)

### Notifications
- Desktop notifications — system-level popups for new messages (browser permission required)
- Notify on @mention only — limit notifications to messages that mention you
- Notification sound — plays a sound when a notification fires

### Privacy
- Read receipts
- Typing indicators
- Online presence

## Requirements

- Node.js 20.19+ or 22.12+ (required by Vite 7)
- A Matrix account (defaults to `https://matrix.gamebler.xyz`; other homeservers are supported)

## Development

```bash
npm install
npm run dev
```

Opens at `http://localhost:5173`.

## Production build

```bash
npm run build
```

Outputs static files to `dist/`. Deploy to any static host (Netlify, Vercel, Cloudflare Pages, nginx, etc.).

The app must be served over HTTPS in production — the Matrix SDK requires a secure context.

## Godot game portal

The Godot Web export embeds this client in a full-screen iframe and shows the responsive
“Return to Game” control in the client. That control sends a `postMessage` to the game page,
which validates the PurpleShoe origin before closing the iframe and resuming the game.
The portal URL uses `?source=godot`; Matrix sessions are transferred with a short-lived,
single-use ticket in the URL fragment, never with an access token in the URL.

In production, serve the client from `https://gamebler.xyz` and proxy
`/api/matrix/handoff` and `/api/matrix/handoff/redeem` to the Node API on that same origin.
The API must use HTTPS. The Windows, Linux, and Android game builds currently open the
client in the system browser; their in-game “Return to Game” control returns to the game window,
while the page's return control can message the game only when it is hosted in the Web
export's iframe.

### nginx example

```nginx
server {
    listen 443 ssl;
    root /var/www/purpleshoe/dist;
    index index.html;

    location / {
        try_files $uri $uri/ /index.html;
    }
}
```

## Tech stack

- [Vite](https://vitejs.dev/) — build tool
- [matrix-js-sdk](https://github.com/matrix-org/matrix-js-sdk) — Matrix client SDK
- [emoji-picker-element](https://github.com/nolanlawson/emoji-picker-element) — emoji picker
