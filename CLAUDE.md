# Technical Guide for AI Agents (CLAUDE.md)

This document provides specialized technical context for AI agents working on the Sitcom Studio codebase.

## 🤖 Agent Context
You are operating in a hybrid Python/GDScript environment. `orchestrator.py` is the "Client/Director" (Groq writes a themed episode → edge-tts renders audio → pushes events over WebSocket). The Godot project (`main.tscn` + `main.gd`) is the "Server/Stage": it hosts the WebSocket **server**, animates the two actors, and plays the audio/laughs.

## 📐 Critical Hierarchies
To keep realistic humanoid proportions and avoid the "Potato Effect" (inherited scaling distortions), the character rig follows one rule: **scaled meshes are always leaf nodes; only *unscaled* `Node3D` pivots are ever nested.** This allows articulated knees/elbows without distortion. Face parts are flat siblings under `BodyA`/`BodyB` (suffix `A` for Alan, `B` for Bridgette).

There are **three actors**: `Alan` (suffix `A`), `Bridgette` (suffix `B`), and `Kessler` (suffix `K`) — a Kramer-esque neighbor who lives in the `grocery` set and only ever appears there (see Multi-Scene). All three share the same flat rig; Kessler reuses the shared limb meshes but has his own distinct shirt/pants/hair/skin materials and his **own** `AnimationLibrary_kessl` (the body clips with `K`-suffixed track paths).

**Rig (Alan shown; Bridgette and Kessler mirror with `B`/`K` suffixes):**
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
- `play_audio` → 70% actor single / 30% wide; `trigger_laugh` and `play_stinger` cut to wide. All camera lookups are per-scene via `SCENES[current_scene]` (see Multi-Scene below); `set_scene` cuts to that set's `ExteriorCam` for the establishing pan.

## 🏙️ Scene / Environment
`main.tscn` is a New-York-inspired open studio loft (exposed-brick north wall, big industrial window with a dusk skyline, ceiling, warm evening lighting). Furniture is grouped under `ApartmentEnvironment` in containers: `LivingArea`, `Kitchen`, `Bedroom`, `Windows`, `Decor`. Do not rename the nodes `main.gd` depends on: `CouchBase/Seat1`·`Seat2`, the three cameras, `LaughPlayer`, `Alan/VoiceA`, `Bridgette/VoiceB`.

**Set-dressing pattern:** every set is a CSG blockout (boxes/cylinders/spheres + flat `StandardMaterial3D`s — the shared `materials/m_*.tres` plus a handful of inline `StandardMaterial3D` sub_resources: `…_cream/brown/orange/pink/blue` for cafe/grocery dressing, alongside the character ones). **Dressing lives in its own container `Node3D`s so it never moves the nodes `main.gd` resolves by path** — coffee shop dressing is under `CoffeeShopEnvironment/CafeDressing` (extra tables/stools, coffee urn, donut/Timbits display, register, second pendant) and grocery dressing under `GroceryEnvironment/Aisles`·`Produce`·`Checkout2` (product blocks, produce mounds, conveyor, second cart); each `*Exterior` has a `StreetDressing` child (TTC-style poles + overhead streetcar wire, a "TTC 504" stop sign, a mailbox). **Signage/menus/prices use `Label3D`** (the only text in the project): storefront names `TIMMY HO'S` / `NO THRILLS`, the cafe menu board, grocery aisle numbers + `$`-price tags + a `NO THRILLS` interior banner + a `SALE` starburst, and the apartment's `247 QUEEN ST W` building plate. Label3D defaults face **+Z** — which is toward the audience-side cameras and the `ExteriorCam`s, so back-wall/facade signs need no rotation. CSG props have **no collision**; actors translate through geometry, so blocking dressing sits toward the walls (out of the wander lane, local x≈-6..6 / z≈-4..4). The `ExteriorCam`s were pulled back/widened so the `StreetDressing` reads during the establishing pan.

## 🗺️ Multi-Scene (Toronto) — Apartment / Coffee Shop / Grocery
The show is set in downtown Toronto and plays across **three sets**, each a sibling `Node3D` under `ComedyStage`: `ApartmentEnvironment` (origin), `CoffeeShopEnvironment` ("Timmy Ho's", a Tim Hortons-style café, **offset world X+40**) and `GroceryEnvironment` ("No Thrills", a No Frills-style discount grocer, **offset world X+80**). They are **separate world-space regions, not visibility-toggled** — toggling would kill the global `WorldEnvironment` sky/ambient that lives under `ApartmentEnvironment`. Each region carries its own geometry, lights (CSG built from the shared `res://materials/m_*.tres`), a camera trio (`Camera3D`/`CameraAlan`/`CameraBridgette`), a `LaughPlayer`, an **exterior facade + `ExteriorCam`**, and seat markers — except the grocery, which has **empty seat paths so actors only wander the aisles** (apartment uses `CouchBase/Seat1·2`, coffee uses `CafeTable/SeatC1·2`).

`main.gd` is scene-aware via the `SCENES` dict (`current_scene` defaults to `"apartment"`): it maps each id → its camera/seat/laugh node paths plus **world-space** `spawn_*`/`wander_*` (regions are offset on X, so these include the offset; cameras/seats resolve globally via node paths). The grocery entry additionally carries `cam_k`/`spawn_k` for Kessler. Actors are stored in the `actors` dict keyed by id; **Kessler ("K") is initialized with a `fixed_scene` of `"grocery"`**, which pins his wander bounds/decisions to that set and **excludes him from `_teleport_to_scene`** — he lives permanently in the grocery region (off-camera from the other sets) instead of travelling with the couple. The old hard-coded A/B pairing is gone: `_update_actor` now faces the **nearest** other actor (`_nearest_other`), which naturally keeps interactions within a set since the regions are far apart. `_switch_camera` resolves the speaker's single by id (`cam_a`/`cam_b`/`cam_k`) and cuts wide if that set has no camera for them; `play_line` plays through the actor's stored `Voice<id>` node. `_switch_camera`, `_cut_to_wide`, `play_laugh`, `play_stinger`, and `_make_decision` all read `SCENES[current_scene]`. A **`set_scene` event** runs `_set_scene()`: cut to the destination's `ExteriorCam`, play a stinger, slow-truck the camera across the facade for `ESTABLISH_PAN` (4.0s) via a `Tween`, then **teleport both actors** into the new region (reset to `WANDERING`) and cut to the new wide cam — the classic sitcom "cut to the building" beat. Keep the per-scene node names (`Camera3D`, `CameraAlan`, `CameraBridgette`, `ExteriorCam`, `LaughPlayer`, seat markers) consistent so the `SCENES` paths resolve.

## ✍️ Comedy Writing (Episodes)
`orchestrator.py` generates one **episode** per outer loop, not isolated skits. Each episode is a single Groq call (`generate_episode(client, topic)`) — a stateless ~940-token input → ~750-token typical output request (≈3k context window total; see the **LLM REQUIREMENTS** comment block atop `orchestrator.py` for the full sizing when swapping providers) seeded from the curated `TOPICS` rotation (The Sopranos, The Matrix, Nicolas Cage, history, philosophy, music, space, mythology, plus Toronto-flavored topics — the TTC, Drake/the 6ix, Canadian winter, the CN Tower, aggressive politeness; no immediate topic repeats). Alan & Bridgette are framed as a late-20s couple living together in Toronto. The `SYSTEM_PROMPT` asks for a cohesive 3–5 skit arc (hook → banter → escalation → heartfelt button) sharing one `theme`, with a running-bit callback paid off in the finale and a few genuine low-risk facts woven in — comedy-first, never mean. Each skit is tagged with a **`scene`** of `"apartment"`/`"coffee_shop"`/`"grocery"` so the episode hops locations (Timmy Ho's, No Thrills). The model returns `{ "theme": str, "skits": [ { "scene": str, "lines": [ {"actor","line"} ] } ] }`; `_coerce_skit` validates the scene (defaults `"apartment"`) and **normalizes each line's `actor` to one of `A`/`B`/`K`** (unknown → `A`), and since **Kessler ("K") is grocery-only**, any stray `K` line in a non-grocery skit is demoted to Alan. `generate_episode` tolerantly normalizes wrappers/bare arrays and soft-clamps to `MAX_SKITS_PER_EPISODE` (5). The `SYSTEM_PROMPT` frames Kessler as an eccentric neighbor used *sparingly* (most episodes skip him; he only turns up at No Thrills). `[LAUGH]` still marks punchlines that should cue the laugh track.

**Scene transitions in playback:** `main_loop` tracks `current_scene`. Before each skit, if its `scene` differs it sends a `set_scene` event and waits `SCENE_TRANSITION_GAP` (~5.5s, matching Godot's `ESTABLISH_PAN` + hold) for the visual establishing shot — this *replaces* the normal between-skit stinger at that boundary; same-location boundaries still use `trigger_stinger`+`STINGER_GAP`. `send_ev.py` is a tiny dev helper to fire one event by hand (e.g. `python send_ev.py set_scene grocery`).

**Playback flow (`main_loop` → `play_line`):** per line, TTS → `play_audio` → wait the clip's *measured* `mp3_duration` (+`LINE_PAUSE`) so actors never talk over each other; `[LAUGH]` lines wait `LAUGH_WAIT`+`POST_LAUGH_PAUSE`. A stinger (`STINGER_GAP`) bridges skits *within* an episode; a longer `EPISODE_GAP` + stinger separates whole episodes. Audio files are named `ep{N}_skit{s}_line{i}.mp3` (regenerated each run).

## 📡 WebSocket Protocol
The Python orchestrator pushes JSON payloads to `ws://localhost:9000` (Godot is the server, Python the client; one connection per line).

**Play Audio Event:** (`actor` is `"A"` Alan / `"B"` Bridgette / `"K"` Kessler; an unknown id is ignored)
```json
{ "event": "play_audio", "file": "ep1_skit0_line0.mp3", "actor": "A" }
```

**Trigger Laugh Event:**
```json
{ "event": "trigger_laugh" }
```

**Play Stinger Event** (between-skit musical transition; cuts to the wide shot, plays a random `audio/stinger1..6.mp3` through the non-positional `StingerPlayer`):
```json
{ "event": "play_stinger" }
```

**Set Scene Event** (visual establishing-shot transition between locations; cuts to the destination set's `ExteriorCam`, plays a stinger, slow-pans the facade for `ESTABLISH_PAN`, teleports the actors in, then cuts to that set's wide cam):
```json
{ "event": "set_scene", "scene": "coffee_shop" }
```
`scene` is one of `"apartment"`, `"coffee_shop"`, `"grocery"`; unknown ids are ignored.

Audio nodes: `Alan/VoiceA`, `Bridgette/VoiceB` & `Kessler/VoiceK` (3D dialogue), each set's `LaughPlayer` (3D laugh track, `volume_db -8`), `StingerPlayer` (root, non-positional music). Inter-skit pacing lives in `orchestrator.py` (`STINGER_GAP`, `SCENE_TRANSITION_GAP`, `SKIT_INTRO_PAUSE`) — the long rest was replaced by a short stinger transition.

## 🛠️ Known Quirks & Established Fixes
- **Forward Axis:** Godot's `-Z` is forward. Facial features must sit at negative Z relative to the head center.
- **Animation Paths:** track paths are relative to the `AnimationPlayer`'s parent (`BodyA`/`BodyB`), e.g. `LegLPivotA/KneeLPivotA:rotation_degrees`.
- **Rotation Safety:** when using `look_at()` / `Basis.looking_at()`, zero the direction vector's Y to prevent gimbal-lock crashes.
- **One-shot pose hold:** a non-looping clip clears `current_animation` when it finishes — track the intended clip yourself (see `_play_body`) so a held pose isn't retriggered.
- **Editor screenshots are stale:** the godot-ai `editor_screenshot` `viewport` source only redraws when the editor is focused. Verify visuals with `source="cinematic"` or `project_run` + `source="game"` instead.
- **edge-tts can return empty audio silently:** `Communicate.save()` occasionally writes a **0-byte mp3 without raising**. A dead clip wedged the stage — Godot set `speaking=true` but a zero-length `AudioStreamMP3` never fires `finished`, so the mouth flapped forever with no sound. Guarded on both sides: `create_tts` verifies the file has real bytes (>512) and retries once before returning `False` (the line is then skipped); `main.gd` `play_line` skips any stream with `get_length() <= 0` and a `speak_until` watchdog in `_update_face` force-clears a `speaking` state that outlives its clip.

## ▶️ How to Run (two separate steps)
The orchestrator and the stage are launched independently — pressing Play in Godot does NOT start the orchestrator, and `start_comedy.ps1` does NOT launch Godot:
1. **Stage:** press Play in Godot (or run the scene) → starts the WebSocket *server* on `:9000`; actors wander silently until a client connects.
2. **Director:** run `start_comedy.ps1` (sets `GROQ_API_KEY`, runs `orchestrator.py`) → the *client* connects and feeds `play_audio` / `trigger_laugh` / `play_stinger` / `set_scene` events. The orchestrator opens a fresh short-lived connection per message.

No-Groq alternative for step 2: `python ws_smoke.py` replays existing `audio/*.mp3` through the same events (its demo skits hop apartment → coffee_shop → grocery to exercise the transitions). For a single manual event, `python send_ev.py <event> [arg]`.

> Note: `start_comedy.ps1` holds the Groq key in plaintext — treat it as a secret (don't share/commit it; rotate if it leaks).

## ✅ TODO / Next Steps
- **Full end-to-end run:** with a valid `GROQ_API_KEY`, run `orchestrator.py` against the running game to validate generation → TTS → playback and confirm the new stinger/laugh/pacing feel and per-skit scene hops + establishing shots. (`ws_smoke.py` already covers the dependency-free multi-scene path.)
- **Set dressing polish:** ~~the coffee shop / grocery interiors and exterior facades are functional CSG blockouts~~ **done** — both interiors are dressed to roughly apartment-level fidelity, all three storefronts carry readable `Label3D` parody signage (`TIMMY HO'S` / `NO THRILLS`), and each facade has Toronto street dressing (streetcar wire + poles, a `TTC 504` stop, a mailbox); see the Scene/Environment "Set-dressing pattern" note. Remaining nice-to-haves: real product/label textures instead of flat colors, a few more cafe/grocery props, and animating the establishing-pan framing per facade. Tuning the parody names in `SYSTEM_PROMPT` is still optional.

## 💡 Future Development Ideas
- **Kessler polish:** the third character (eccentric, Kramer-esque grocery neighbor) is **implemented** — full `K`-suffixed rig in the grocery region, `VOICES["K"]` (`en-US-DavisNeural`), `CameraKessler`, `fixed_scene` pinning, and grocery-only prompt/validation (see the rig + Multi-Scene + Comedy Writing sections above). Remaining nice-to-haves: make his hair read wilder, give him a signature entrance/prop, and have him occasionally walk into frame mid-skit rather than already standing in the aisle.
- **Two-person couch / hands-on-lap:** refine `sit_v1` so resting hands land naturally and both actors share the couch (and the coffee-shop café table) cleanly.
- **Prop Interaction:** trigger events like "Alan drinks from a mug" or "Bridgette opens the fridge".
- **Dynamic Lighting:** shift each set's lighting by time of day or skit "mood".
