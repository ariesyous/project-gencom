# AI Sitcom Studio: Alan & Bridgette

An automated 3D sitcom, baked daily and hosted for free on GitHub Pages, powered by Godot 4 (Web export) and an LLM via OpenRouter.

## 🎭 Overview
Two AI characters, **Alan** and **Bridgette** (plus their eccentric neighbor **Kessler**), wander an open-concept Toronto apartment, a coffee shop, and a grocery store, playing out episodic skits. There is no live backend — episodes are generated ahead of time by a GitHub Action and played back entirely client-side in the browser.

## 🛠️ System Architecture

### 1. The Bake Pipeline (`bake_episode.py`, GitHub Actions)
Runs on a daily schedule (`.github/workflows/bake-episode.yml`), with no live Godot connection:
- **Script Generation:** Fetches a JSON-formatted episode from an LLM via OpenRouter.
- **Voice Synthesis:** Generates character-specific audio using `edge-tts`.
- **Publishing:** Writes `shows/ep{N}/episode.json` (a flat, ordered event trace) + `shows/ep{N}/audio/*.mp3`, and updates `shows/manifest.json` — committed straight to the repo.

### 2. The Player (Godot 4 Web export)
The 3D environment and character logic live in `main.tscn` and `main.gd`, exported to HTML5/WASM:
- **Episode Sequencer:** Fetches `shows/manifest.json` and an episode's `episode.json` over HTTP, then walks its events, firing the same playback functions a live WebSocket dispatcher used to call.
- **Autonomous Behaviors:** Characters decide when to walk, stand, or sit independently.
- **Dynamic Multi-Cam:** An automated "Director" logic cuts between wide shots and close-ups based on which character is speaking.
- **Integrated Laugh Track:** Plays randomized audience laughter after AI-tagged punchlines.

### 3. Deployment (`.github/workflows/deploy-pages.yml`)
Exports the Godot `Web` preset (cached — an episode-bake commit that only touches `shows/` skips the re-export) and publishes it alongside `shows/` to GitHub Pages. A small menu (injected via the export preset's `html/head_include`) lets visitors pick an episode; the default is to autoplay a random one.

## 🚀 Local Development

### Prerequisites
- **Godot 4.7+**
- **Python 3.10+**
- An **OpenRouter API Key** (for baking new episodes locally).

### Setup
```bash
pip install -r requirements.txt
```

### Baking an episode locally
```bash
export OPENROUTER_API_KEY=...   # or $env:OPENROUTER_API_KEY on Windows
python bake_episode.py
python prune_episodes.py
```

### Testing playback in the editor
The Godot sequencer fetches everything over HTTP (same as the deployed Web build), so native/editor builds need a local server to resolve relative URLs against:
```bash
python -m http.server 8000
```
Then open the project in Godot and press **Play** (F5) — `main.gd`'s `LOCAL_DEV_BASE_URL` points at `http://localhost:8000/`.

## 📖 Further Reading
- For AI agents looking to contribute, see [CLAUDE.md](./CLAUDE.md).
