# Technical Guide for AI Agents (AGENTS.md)

This document provides specialized technical context for AI agents working on the Sitcom Studio codebase.

## 🤖 Agent Context
This is now a static, self-contained show with no live backend: `bake_episode.py` runs in CI (OpenRouter + edge-tts) and writes `shows/ep{N}/episode.json` + audio; the Godot project, exported to Web (HTML5/WASM), fetches that data over HTTP and plays it back locally. There is no WebSocket anymore. **This file is a stale, older snapshot — see [CLAUDE.md](./CLAUDE.md) for the authoritative, up-to-date architecture** (rig, animation, cameras, multi-scene, the baked episode schema, and how to run everything).

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

## 📡 Baked Event Schema (see CLAUDE.md — this section is superseded)
There is no WebSocket protocol anymore. `main.gd` fetches a baked `episode.json` (an ordered `events` array: `play_audio`/`trigger_laugh`/`play_stinger`/`set_scene`/`skit_boundary`) and interprets it locally. Full schema and pacing constants are documented in [CLAUDE.md](./CLAUDE.md#-baked-event-schema-formerly-the-websocket-protocol).

## 🛠️ Known Quirks & Established Fixes
- **Forward Axis:** Godot's `-Z` is forward. Facial features must sit at negative Z relative to the head center.
- **Animation Paths:** track paths are relative to the `AnimationPlayer`'s parent (`BodyA`/`BodyB`), e.g. `LegLPivotA/KneeLPivotA:rotation_degrees`.
- **Rotation Safety:** when using `look_at()` / `Basis.looking_at()`, zero the direction vector's Y to prevent gimbal-lock crashes.
- **One-shot pose hold:** a non-looping clip clears `current_animation` when it finishes — track the intended clip yourself (see `_play_body`) so a held pose isn't retriggered.
- **Editor screenshots are stale:** the godot-ai `editor_screenshot` `viewport` source only redraws when the editor is focused. Verify visuals with `source="cinematic"` or `project_run` + `source="game"` instead.

## ▶️ How to Run
See [CLAUDE.md](./CLAUDE.md#️-how-to-run) — in short: `python bake_episode.py` (needs `OPENROUTER_API_KEY`) bakes an episode with no Godot involved; the Godot Web export plays whatever's in `shows/manifest.json`. For local editor testing, serve the repo with `python -m http.server 8000` and Play the scene.

## ✅ TODO / Next Steps
See CLAUDE.md's TODO section for the current list (Web export verification, CI dry runs).

## 💡 Future Development Ideas
- **Two-person couch / hands-on-lap:** refine `sit_v1` so resting hands land naturally and both actors share the couch cleanly.
- **Prop Interaction:** trigger events like "Alan drinks from a mug" or "Bridgette opens the fridge".
- **Dynamic Lighting:** shift the apartment's lighting by time of day or skit "mood".
