# AI Sitcom Studio: Alan & Bridgette

An automated 3D sitcom production environment powered by Godot 4 and Groq AI. 

## 🎭 Overview
This project simulates a live sitcom set in an open-concept New York studio apartment. Two AI characters, **Alan** and **Bridgette**, autonomously wander their home, sit on the couch, and engage in funny, episodic skits generated in real-time by a Large Language Model.

## 🛠️ System Architecture

### 1. The Brain (Python Orchestrator)
Located in `orchestrator.py`, this script manages the "performance lifecycle":
- **Script Generation:** Fetches JSON-formatted sitcom scenes from Groq (`openai/gpt-oss-120b`).
- **Voice Synthesis:** Generates character-specific audio using `edge-tts`.
- **Engine Control:** Communicates via WebSockets to trigger animations and audio in Godot.

### 2. The Stage (Godot 4 Engine)
The 3D environment and character logic live in `main.tscn` and `main.gd`:
- **WebSocket Server:** Listens on port 9000 for performance commands.
- **Autonomous Behaviors:** Characters decide when to walk, stand, or sit independently.
- **Dynamic Multi-Cam:** An automated "Director" logic cuts between wide shots and close-ups based on which character is speaking.
- **Integrated Laugh Track:** Plays randomized audience laughter after AI-tagged punchlines.

## 🚀 Getting Started

### Prerequisites
- **Godot 4.3+**
- **Python 3.10+**
- A **Groq API Key**.

### Setup
1. Clone the repository.
2. Install Python dependencies:
   ```bash
   pip install openai edge-tts websockets
   ```
3. Place 4 laugh track files in `res://audio/` named `laugh1.mp3` through `laugh4.mp3`.

### Running the Show
1. **Launch the Engine:** Open the project in Godot and press **Play** (F5).
2. **Launch the Cast:** Open a terminal and run the wrapper script:
   ```powershell
   .\start_comedy.ps1
   ```
   *(Note: You will need to paste your Groq API key into the top of `start_comedy.ps1` first).*

## 📖 Further Reading
- For AI agents looking to contribute, see [CLAUDE.md](./claude.md).
- For established project conventions, see [GEMINI.md](./GEMINI.md).
