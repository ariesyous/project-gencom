# Project GenCom: AI Sitcom Studio

This project is a statically-hosted 3D sitcom: a GitHub Action bakes episodes ahead of time (no live orchestrator), and a Godot 4 Web export plays them back client-side on GitHub Pages. **See [CLAUDE.md](./CLAUDE.md) for the authoritative, up-to-date architecture** — this file is a lighter pointer, not the source of truth.

## System Architecture

### 1. Bake pipeline (`bake_episode.py`, run by `.github/workflows/bake-episode.yml`)
- **Brain:** Connects to an LLM via OpenRouter to generate multi-line episodic comedy skits in JSON format.
- **Voice:** Uses `edge-tts` to synthesize speech for Alan, Bridgette, and Kessler.
- **Publish:** Writes `shows/ep{N}/episode.json` (a flat, ordered event trace — no WebSocket, no live Godot connection) + audio, and updates `shows/manifest.json`.

### 2. Godot 4 Engine (exported to Web/WASM)
- **Sequencer:** Fetches `shows/manifest.json` + an episode's JSON over HTTP and walks its events locally (`main.gd`'s `_sequencer_main_loop`).
- **Visuals:** Three CSG-built sets (apartment, coffee shop, grocery) with articulated humanoid actors.
- **Logic (`main.gd`):**
    - Manages an autonomous state machine for actor behaviors (Wander, Head to Seat, Sit, Offstage/Entering for Kessler).
    - Routes audio and mouth animations to the correct character.
    - Implements a dynamic "Director" camera system that cuts between master and close-up shots based on speaker.

## Technical Conventions

### GDScript (`.gd`)
- **Hierarchy Awareness:** Always use `get_node_or_null()` or check `has_node()` when referencing character-specific components like `VoiceA` or `MouthB` to prevent runtime crashes.
- **Coordinate System:** Actors move on the `y=0` plane. Always zero out the Y component of target vectors to prevent "upward" rotation crashes in `Basis.looking_at`.
- **HTTP fetches, not polling a socket:** the sequencer awaits `HTTPRequest.request_completed` per fetch (manifest, episode JSON, each line's mp3) instead of polling a `WebSocketPeer` every frame.

### Python (`.py`)
- **Async Workflow:** All network and TTS operations must be non-blocking. Use `asyncio.get_running_loop().run_in_executor()` for synchronous API calls.
- **One episode per process:** `bake_episode.py` bakes exactly one episode per invocation and exits — the daily cadence is the GitHub Actions cron, not a loop in the script.

## Environment Setup
- **OpenRouter API:** Requires `OPENROUTER_API_KEY` (a GitHub Actions secret in production); `OPENROUTER_MODEL` optionally overrides the default `openrouter/free`.
- **Audio:** Baked episode dialogue lives under `shows/ep{N}/audio/` and is fetched over HTTP at playback time, not bundled into the Godot export. Fixed sound effects (`laugh1-4.mp3`, `stinger1-6.mp3`) remain bundled under `res://audio/`.

## How to Run
See [CLAUDE.md](./CLAUDE.md#️-how-to-run) for the full picture. In short:
```bash
pip install -r requirements.txt
export OPENROUTER_API_KEY=...
python bake_episode.py
python -m http.server 8000   # for local editor testing only
```
Then Play `main.tscn` in the Godot editor.
