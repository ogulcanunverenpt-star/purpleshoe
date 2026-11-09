# PurpleShoe

PurpleShoe is a multiplayer football game with a connected open-world social hub. Explore a
continuous world, meet other players, and enter football activities through in-world portals.

## Game overview

The main game is in [`voip-3d/`](./voip-3d/), a Godot 4 project. Its default entry point is the
account and lobby flow in `lobby.tscn`.

- **11-a-side football:** Each side has ten field players and a goalkeeper. A human player controls
  their selected player while the ROBOT side and the remaining teammates are controlled by the
  game's football AI.
- **Free kicks:** A two-player mode focused on aiming, shooting, goalkeeping, and competing to the
  target score.
- **Open-world exploration:** Walk or drive between the city, countryside, and old town; discover
  districts and pursue the Grand Tour goal of reaching the old-town plaza.
- **Social play:** Meet other players, use spatial voice chat, send messages, and join football
  matches or voice-chat rooms through portals and invitations.

## Highlights

- Football movement, dribbling, passing, shooting, tackling, formations, restart situations, and
  AI-controlled teammates and opponents.
- Match and free-kick lobbies, team and role selection, invitations, and online presence.
- A streamed open world with multiple districts, ambient traffic, pedestrians, NPCs, vehicles,
  changing time and weather, and local discovery saves.
- Matrix-based messaging and voice-chat integration, including a responsive web client.
- WebSocket networking for browser-compatible play and UDP/ENet for desktop and Android builds.

## Technology stack

| Area | Technology |
| --- | --- |
| Game client | Godot 4.7, GDScript, Godot MultiplayerAPI |
| Real-time game networking | WebSocket or UDP/ENet |
| Messaging and identity | Matrix; `matrix-js-sdk` in the web client |
| Web messaging client | Vanilla JavaScript, Vite |
| Bundled service source | Node.js, Express, Socket.IO, PostgreSQL/SQLite libraries |
| World and asset utilities | Python |

The game project and bundled services have separate responsibilities and setup requirements. The
`server/` directory runs the account API and manages game rooms as well as a legacy firewall-agent
and log-management service. The install script prepares the game and server dependencies but does
not start the Node service. Server credentials and local environment settings are intentionally not
included; configure services from their supplied example files before deploying them.

## Requirements

- Windows with PowerShell for the included install/check script.
- Godot 4.7 or a compatible Godot 4.7 build. The project is configured for the GL Compatibility
  renderer.
- Node.js 20.19+ or 22.12+ for the Matrix web client (Vite 7); Node.js 18+ for the bundled Node
  service.
- Python 3 only if you need to regenerate open-world data or restore assets.

## Run the game on Windows

Clone this repository, then run the install script from the repository root. It imports project
resources, installs missing server dependencies, performs headless startup checks, records the Godot
path for the server, and launches the game:

```powershell
.\install.ps1
```

In a second terminal, start the service before logging in to the game:

```powershell
Set-Location .\server
npm start
```

The service starts the shared game rooms and all portal rooms before accepting API requests. This
starts 19 headless Godot processes and can take time and substantial memory. Leave the terminal
open while playing; stop the service with Ctrl+C. If startup reports an occupied port, stop the
other service using that port and retry. The local API uses TCP 3000, the legacy listener uses
TCP 8000, and the game rooms use WebSocket TCP ports 12882–12900. Private rooms use TCP
12810–12849. Port 12806 is for manually hosted games, not the shared open world.

The defaults are for a game client on the same machine. For LAN access set `SERVER_HOST` in
`server/.env` to the server's reachable LAN address, configure the client API URL accordingly, and
allow the required TCP ports through the firewall. `GODOT_PATH` or `VOIP_3D_EXE` can override the
Godot path saved by the installer. Restart the service after changing configuration.

Windows release exports use the production API by default. To test an export against the local
service, start it from PowerShell with:

```powershell
$env:PURPLESHOE_SERVER_URL = 'http://127.0.0.1:3000'
.\voip-3d.exe
```

Release builds accept HTTPS URLs or HTTP loopback URLs for this override. Rebuild the export after
updating the project; previously exported executables do not include these fixes.

If Godot is not on `PATH`, pass its executable explicitly:

```powershell
.\install.ps1 -GodotPath 'C:\Tools\Godot_v4.7.2-stable_win64.exe'
```

To open the project in the editor after the checks:

```powershell
.\install.ps1 -Editor
```

You can also open `voip-3d/project.godot` directly in Godot. To run the open-world scene on its own,
select `voip-3d/openworld/main.tscn`.

## Networking and services

The game can use WebSocket or UDP/ENet transport. Browser clients require WebSocket; browser
deployments served over HTTPS must connect through `wss://`. UDP/ENet is available to desktop and
Android clients. A server listens on one transport at a time.

For manual testing, an open-world multiplayer server can be started from the game project directory
instead of the Node-managed server (do not run both on the same port):

```powershell
godot --headless --path . -- --server --mode overland --transport ws --port 12897
```

For details about shared rooms, portal ports, transport selection, and the web deployment
requirements, see [`voip-3d/openworld/INTEGRATION.md`](./voip-3d/openworld/INTEGRATION.md).

The Matrix web client is in `server/cundai/`. To run its development server:

```powershell
Set-Location .\server\cundai
npm install
npm run dev
```

The client needs a Matrix account and a configured API for the secure in-game session handoff.
Production deployments must use HTTPS. The Node service source is in `server/`; use its
`.env.example` as a starting point and supply your own secrets and service configuration. Do not
commit credentials, database files, uploads, or generated dependencies.

## Controls

### Football match

| Input | Action |
| --- | --- |
| Arrow keys | Move |
| E | Sprint |
| D | Shoot / tackle |
| S | Short pass |
| A | Long pass / sliding tackle |
| W | Through ball |
| Q + W | Lofted through ball |
| C | Mark |
| Q | Switch player |
| G | Goalkeeper control |

For a pass or shot, use the arrows to choose the direction and hold the action key to adjust its
power; release it to kick. Short passes and through balls are assisted toward a teammate in that
direction. `Q` switches to the nearest teammate.

### Open world

| Input | Action |
| --- | --- |
| WASD or arrow keys | Move |
| Space | Jump |
| E | Use a nearby portal |
| V | Push to talk |

Touch controls are available on supported mobile screens. Portal and vehicle interactions are
prompted in the world.

## Project layout

```text
.
├── install.ps1             # Windows import, scene checks, and launch helper
├── server/
│   └── cundai/              # Matrix web messaging client
└── voip-3d/
    ├── lobby.tscn           # Default game entry scene
    ├── football_match_controller.gd
    ├── free_kick_controller.gd
    └── openworld/            # Open-world scenes, data, scripts, and assets
```

## Licensing and third-party assets

This repository contains components and assets with different licensing terms; there is no single
license that covers everything. The Godot project includes an MIT license in
[`voip-3d/LICENSE`](./voip-3d/LICENSE). The EmacArt asset terms in
[`voip-3d/LICENSE.txt`](./voip-3d/LICENSE.txt) allow use in personal and commercial projects but
do not allow reselling or redistributing the assets as standalone files or as an asset pack.

The integrated open-world source and its third-party assets have separate terms. Its upstream
project does not provide a single license covering all included material. Review the applicable
asset and source licenses before redistributing or publishing a build.
