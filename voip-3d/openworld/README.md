# Open-World Module

This folder contains the open-world module integrated into the PurpleShoe Godot game. It provides
a streamed exploration world with a city, countryside, and old-town district, plus vehicles,
pedestrians, NPCs, ambient traffic, changing time and weather, and activity portals.

The integrated version runs on local project data and supports multiplayer through the game's
Godot networking layer. It does not use the upstream Supabase, CDN, or LLM/TTS services. Player
location and discovered districts are saved locally.

For current integration behavior, multiplayer setup, transport requirements, asset restoration,
and licensing notes, see [`INTEGRATION.md`](./INTEGRATION.md).
