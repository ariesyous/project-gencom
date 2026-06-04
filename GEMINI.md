# Project GenCom: AI Sitcom Studio

This project is an AI-driven 3D sitcom environment using Godot 4 and a Python orchestration layer.

## System Architecture

### 1. Python Orchestrator (`orchestrator.py`)
- **Brain:** Connects to Groq (using `openai/gpt-oss-120b` or `llama-3.3-70b-versatile`) to generate multi-line episodic comedy skits in JSON format.
- **Voice:** Uses `edge-tts` to synthesize speech for two actors (Alan and Bridgette).
- **Control:** Acts as a WebSocket client to push events (audio playback, laugh triggers) to the Godot engine.

### 2. Godot 4 Engine
- **Server:** Runs a WebSocket server on `ws://localhost:9000` to receive performance signals.
- **Visuals:** An open-concept studio apartment built with CSG primitives, featuring articulated humanoid actors.
- **Logic (`main.gd`):** 
    - Manages an autonomous state machine for actor behaviors (Wander, Head to Seat, Sit).
    - Routes audio and mouth animations to the correct character.
    - Implements a dynamic "Director" camera system that cuts between master and close-up shots based on speaker.

## Technical Conventions

### GDScript (`.gd`)
- **Hierarchy Awareness:** Always use `get_node_or_null()` or check `has_node()` when referencing character-specific components like `VoiceA` or `MouthB` to prevent runtime crashes.
- **Coordinate System:** Actors move on the `y=0` plane. Always zero out the Y component of target vectors to prevent "upward" rotation crashes in `Basis.looking_at`.
- **WebSocket Polling:** Ensure `socket.poll()` is called in `_process` to keep the network buffer clear.

### Python (`.py`)
- **Async Workflow:** All network and TTS operations must be non-blocking. Use `asyncio.get_running_loop().run_in_executor()` for synchronous API calls.
- **Timing:** Use dynamic duration multipliers for speech (`word_count * multiplier`) and include "beats" (0.4s - 1.5s) for comedic timing and laugh tracks.

## Environment Setup
- **Groq API:** Requires `GROQ_API_KEY` set in the environment or via the `start_comedy.ps1` wrapper.
- **Audio:** All generated MP3s are stored in the `./audio` folder. Godot expects this folder to be within its resource path (`res://audio/`).
- **Laugh Tracks:** Requires `laugh1.mp3` through `laugh4.mp3` in the audio folder for random audience integration.

## How to Run
1. Open the project in Godot 4 and play the `main.tscn` scene.
2. Run the PowerShell wrapper:
   ```powershell
   .\start_comedy.ps1
   ```
