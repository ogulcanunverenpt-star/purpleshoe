# Open-World Integration

This folder integrates the [joseb33w/overland](https://github.com/joseb33w/overland) open-world
project into PurpleShoe's `voip-3d` Godot project. These notes describe the integrated version;
the upstream README's Supabase, CDN, and web-only instructions no longer apply.

## Game flow

```text
Login -> Character selection -> openworld/main.tscn (shared open world)
                                      |
                                      +-- 5 Free Kick portals
                                      +-- 5 Match portals
                                      +-- 5 Voice Chat portals
                                           |
world.tscn / Demo.tscn <--- portal -------+
       |
       +-- "Return to Plaza" ---> shared open world
```

Character selection connects directly to the shared open-world server without replacing
`Demo.tscn`. The open-world entry points in the main lobby use the same server. Each portal has a
fixed room key: players entering the same portal share a room, while different portals use
different rooms. Returning from a match or conference reconnects to the shared open world.

Portal rooms use ports `12882-12896`, the shared open world uses `12897`, and existing shared rooms
use `12898-12900`. The Node room manager uses dynamic ports `12810-12849`; the Python room manager
uses `12850-12881`. These ranges avoid collisions between the managers and the fixed portal/shared
room servers.

## Offline world data

- `world.json`, `quests.json`, models, and audio load from `res://openworld/`. The export preset
  includes the JSON files in the package.
- The Supabase `backend.gd` was removed. `overland_save.gd` saves the player's location and
  discovered districts to `user://overland_save.json` (IndexedDB on the web and app storage on
  Android).
- NPC dialogue is read from `world.json`; the game does not connect to external LLM or TTS services.

## Multiplayer

- `overland_net.gd` broadcasts each player's position, movement state, and selected avatar at
  approximately 20 updates per second. Other players appear with their selected character model.
  Usernames come from `MatchManager.roster`.
- Spatial push-to-talk captures microphone audio through `AudioEffectCapture`, relays it through
  the server to players in the same open-world room, and plays it back with `AudioStreamPlayer3D`
  using distance-based audio. Hold `V` on keyboard or the on-screen **PUSH TO TALK** button on
  mobile. Android requests microphone permission on first use; press the button again after
  granting permission.
- Choose the transport in the menu: **WebSocket** (web, Android, and PC) or **UDP/ENet** (Android
  and PC). A server listens on one transport at a time; web clients can only connect to WebSocket
  servers.
- Start the server from the project root:

  ```powershell
  godot --headless --path . -- --server --mode overland --transport ws --port 12897
  ```

  If `--transport` is omitted, the server uses UDP for backward compatibility.
- Web clients served over HTTPS must use `wss://`. Put the server behind a TLS-terminating reverse
  proxy such as nginx or Caddy, then enter the `wss://` domain and proxy port in the game menu.

## Restoring world assets

```powershell
python openworld/tools/gen_world.py
python openworld/tools/fetch_assets.py
godot --headless --path . --import
```

The current upstream template is not compatible with some of the older Open-World files, so
`shapes.gd`, `wander.gd`, and `terrain.gd` have been replaced with the compatible versions.
`fetch_assets.py` only copies missing files. The upstream CDN no longer hosts `fountain.glb` or
`hero.glb`; the game uses fallback models for them.

## Licensing

The upstream repository does not provide a license file covering the project. KayKit, Quaternius,
Kenney, and other third-party assets and template scripts may have their own terms. Verify each
source's license before redistribution or publication.
