# Technical Guide for AI Agents (AGENTS.md)

This document provides specialized technical context for AI agents working on the Sitcom Studio codebase.

## 🤖 Agent Context
You are operating in a hybrid Python/GDScript environment. `orchestrator.py` is the "Client/Director" (Groq writes a skit → edge-tts renders audio → pushes events over WebSocket). The Godot project (`main.tscn` + `main.gd`) is the "Server/Stage": it hosts the WebSocket **server**, animates the two actors, and plays the audio/laughs.

## 📐 Critical Hierarchies
To keep realistic humanoid proportions and avoid the "Potato Effect" (inherited scaling distortions), the character rig follows one rule: **scaled meshes are always leaf nodes; only *unscaled* `Node3D` pivots are ever nested.** This allows articulated knees/elbows without distortion. Face parts are flat siblings under `BodyA`/`BodyB` (suffix `A` for Alan, `B` for Bridgette).

**Rig (Alan shown; Bridgette mirrors with `B` suffix):**
- `Alan` (Node3D — moved/rotated by `main.gd`)
    - `VoiceA` (AudioStreamPlayer3D)
    - `BodyA` (Node3D — lowered onto the couch when sitting; anim root)
        - `TorsoA` (MeshInstance3D, scaled — shirt)
        - `NeckA`, `HeadA` (skin) — siblings, independent scale
        - Face siblings: `MouthA`, `EyeWhiteLA`/`EyeWhiteRA`, `PupilLA`/`PupilRA`, `BrowLA`/`BrowRA`, `NoseA`, `EarLA`/`EarRA`, `HairA` (Bridgette also `HairBackB`)
        - `AnimationAlan` (AnimationPlayer — drives the pivots below)
        - `ArmLPivotA` / `ArmRPivotA` (shoulder Node3Ds)
            - `UpperArmL` (sleeve), `ForearmL` (skin), `HandL` (skin) — leaf meshes
        - `LegLPivotA` / `LegRPivotA` (hip Node3Ds)
            - `UpperLegL` (pants)
            - `KneeLPivotA` (Node3D) → `LowerLegL` (pants), `FootL` (shoe)

## 🎭 Character Animation & Faces
- **Body clips** live on each `AnimationPlayer` (default library): `idle_v1` (breathing via torso chest-scale + gentle arm sway), `walk_v3` (alternating legs/knees/arms), `sit_v1` (thighs forward, shins down). Built with the MCP `create_simple` pingpong helper.
- **`main.gd` selects clips** via `_play_body()`, which tracks the intended clip in `data["cur_anim"]` — required because a non-looping pose (`sit_v1`) clears `current_animation` on finish and would otherwise retrigger every frame.
- **Mouth flap and blinks are driven from code** (`_update_face`), not animations, so they work over idle/walk/sit. The mouth opens via `MouthA:scale.y` while `speaking`; eyes squash via their `scale.y` on a randomized blink timer. (The old `talk_v4` mouth animation was deleted — it had a duplicate track and auto-played, fighting the mouth scale.)
- **Sitting** drops `BodyA.position.y` to `SIT_BODY_Y` (−0.44) so the pelvis rests on the couch while feet reach the floor.

## 🎥 Cameras
- `ApartmentEnvironment/Camera3D` is the wide establishing shot (default `current`).
- `CameraAlan` / `CameraBridgette` are fixed **audience-side singles** (placed past the open fourth wall at ~`z 6.3`, eye-level, offset L/R, ~37° FOV) that pan to follow the speaker — `_switch_camera()` just selects one and `_update_active_camera()` `look_at`s the speaker's head each frame via `active_cam`. Multi-cam sitcom style: an actor can't wander into them (earlier in-set close-ups caused head-clipping).
- `play_audio` → 70% actor single / 30% wide; `trigger_laugh` and `play_stinger` cut to wide.

## 🏙️ Scene / Environment
`main.tscn` is a New-York-inspired open studio loft (exposed-brick north wall, big industrial window with a dusk skyline, ceiling, warm evening lighting). Furniture is grouped under `ApartmentEnvironment` in containers: `LivingArea`, `Kitchen`, `Bedroom`, `Windows`, `Decor`. Do not rename the nodes `main.gd` depends on: `CouchBase/Seat1`·`Seat2`, the three cameras, `LaughPlayer`, `Alan/VoiceA`, `Bridgette/VoiceB`.

## 📡 WebSocket Protocol
The Python orchestrator pushes JSON payloads to `ws://localhost:9000` (Godot is the server, Python the client; one connection per line).

**Play Audio Event:**
```json
{ "event": "play_audio", "file": "skit_1_line_0.mp3", "actor": "A" }
```

**Trigger Laugh Event:**
```json
{ "event": "trigger_laugh" }
```

**Play Stinger Event** (between-skit musical transition; cuts to the wide shot, plays a random `audio/stinger1..6.mp3` through the non-positional `StingerPlayer`):
```json
{ "event": "play_stinger" }
```

Audio nodes: `Alan/VoiceA` & `Bridgette/VoiceB` (3D dialogue), `ApartmentEnvironment/LaughPlayer` (3D laugh track, `volume_db -8`), `StingerPlayer` (root, non-positional music). Inter-skit pacing lives in `orchestrator.py` (`STINGER_GAP`, `SKIT_INTRO_PAUSE`) — the long rest was replaced by a short stinger transition.

## 🛠️ Known Quirks & Established Fixes
- **Forward Axis:** Godot's `-Z` is forward. Facial features must sit at negative Z relative to the head center.
- **Animation Paths:** track paths are relative to the `AnimationPlayer`'s parent (`BodyA`/`BodyB`), e.g. `LegLPivotA/KneeLPivotA:rotation_degrees`.
- **Rotation Safety:** when using `look_at()` / `Basis.looking_at()`, zero the direction vector's Y to prevent gimbal-lock crashes.
- **One-shot pose hold:** a non-looping clip clears `current_animation` when it finishes — track the intended clip yourself (see `_play_body`) so a held pose isn't retriggered.
- **Editor screenshots are stale:** the godot-ai `editor_screenshot` `viewport` source only redraws when the editor is focused. Verify visuals with `source="cinematic"` or `project_run` + `source="game"` instead.

## ▶️ How to Run (two separate steps)
The orchestrator and the stage are launched independently — pressing Play in Godot does NOT start the orchestrator, and `start_comedy.ps1` does NOT launch Godot:
1. **Stage:** press Play in Godot (or run the scene) → starts the WebSocket *server* on `:9000`; actors wander silently until a client connects.
2. **Director:** run `start_comedy.ps1` (sets `GROQ_API_KEY`, runs `orchestrator.py`) → the *client* connects and feeds `play_audio` / `trigger_laugh` / `play_stinger` events. The orchestrator opens a fresh short-lived connection per message.

No-Groq alternative for step 2: `python ws_smoke.py` replays existing `audio/*.mp3` through the same events.

> Note: `start_comedy.ps1` holds the Groq key in plaintext — treat it as a secret (don't share/commit it; rotate if it leaks).

## ✅ TODO / Next Steps
- **Full end-to-end run:** with a valid `GROQ_API_KEY`, run `orchestrator.py` against the running game to validate generation → TTS → playback and confirm the new stinger/laugh/pacing feel. (`ws_smoke.py` already covers the dependency-free path.)

## 💡 Future Development Ideas
- **Two-person couch / hands-on-lap:** refine `sit_v1` so resting hands land naturally and both actors share the couch cleanly.
- **Prop Interaction:** trigger events like "Alan drinks from a mug" or "Bridgette opens the fridge".
- **Dynamic Lighting:** shift the apartment's lighting by time of day or skit "mood".
