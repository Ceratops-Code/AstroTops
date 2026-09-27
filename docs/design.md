# AstroTops software design

```design-document
{
  "contract_version": 1,
  "document": "docs/design.md",
  "owners": ["AstroTops maintainers"],
  "source_of_truth": [
    {"path": "project.godot", "role": "Godot runtime identity, entry scene, display, input, audio, and renderer configuration"},
    {"path": "main.tscn", "role": "Executable scene entry and script attachment"},
    {"path": "scripts/main.gd", "role": "Implemented game state machine, modes, controls, target orchestration, tractor beam, persistence, and UI"},
    {"path": "scripts/audio_controller.gd", "role": "Implemented generated cues, sound-effect playback, and native text-to-speech requests"},
    {"path": "scripts/player_ship.gd", "role": "Implemented ship movement, rendering, styles, and pilot presentation"},
    {"path": "scripts/planet.gd", "role": "Implemented celestial-body rendering, capture, collision extent, and explosion behavior"},
    {"path": "scripts/meteor.gd", "role": "Implemented meteor-flight and impact behavior"},
    {"path": "export_presets.cfg", "role": "Android package identity, architecture, and launcher-icon export configuration"},
    {"path": "sdlc/sdlc.yml", "role": "Repository build, validation, delivery, and Android installation workflow"},
    {"path": "docs/feature-acceptance.json", "role": "Current requirement-to-observable-test contract"},
    {"path": "scripts/result_records.py", "role": "Runtime owner of bounded validation, test, build, and deployment result records"},
    {"path": "docs/result_records.py.tmpl", "role": "Reusable adoption seed; never runtime authority for this repository"},
    {"path": "docs/design.md", "role": "Architectural rationale, boundaries, quality goals, and maintenance policy"}
  ],
  "update_triggers": [
    "Gameplay state, input, persistence, rendering, speech, or tractor-beam behavior changes",
    "Android identity, packaging, signing, launcher icon, build, deployment, or supported runtime changes",
    "Test-result schema, evidence retention, qualification, or delivery-gate changes",
    "A new external integration, trust boundary, persistent data item, or architectural decision is introduced",
    "The reusable result-record template changes its users, adoption process, or lifecycle"
  ],
  "coverage": {
    "purpose": {"heading": "1 Purpose and goals", "status": "documented"},
    "constraints": {"heading": "2 Constraints and assumptions", "status": "documented"},
    "context": {"heading": "3 System context", "status": "documented"},
    "strategy": {"heading": "4 Solution strategy", "status": "documented"},
    "building_blocks": {"heading": "5 Building blocks", "status": "documented"},
    "runtime": {"heading": "6 Runtime behavior", "status": "documented"},
    "deployment": {"heading": "7 Deployment and operations", "status": "documented"},
    "data": {"heading": "8.1 Data and persistence", "status": "documented"},
    "interfaces": {"heading": "8.2 APIs and integrations", "status": "documented"},
    "protection": {"heading": "8.3 Security and resilience", "status": "documented"},
    "decisions": {"heading": "9 Decisions and alternatives", "status": "documented"},
    "quality": {"heading": "10 Quality scenarios", "status": "documented"},
    "risks": {"heading": "11 Risks and limitations", "status": "documented"},
    "glossary": {"heading": "12 Glossary and references", "status": "documented"},
    "verification": {"heading": "13 Testing and verification", "status": "documented"},
    "governance": {"heading": "14 Ownership and maintenance", "status": "documented"}
  }
}
```

## 1 Purpose and goals

AstroTops is a small, single-player, top-down arcade game for Android and
desktop development. A player chooses a ship, pilot, and color, then flies
through visible celestial targets. Captured targets adopt the ship color. The
run ends after all targets are captured and a meteor finale destroys them; the
game records elapsed and best time.

This document is for gameplay developers, maintainers of the Ceratops delivery
workflow, reviewers, and future asset contributors. Readers should know basic
Godot scenes and GDScript; Python knowledge is needed only for repository
automation.

The priorities, in order, are observable input parity across touch, keyboard,
and gamepad; responsive and readable play on a tablet; deterministic,
artifact-bound qualification; and low operational complexity. Online play,
accounts, telemetry, procedural multi-screen worlds, and proportional
astronomical simulation are non-goals. A future field larger than the viewport
is anticipated, so targeting logic already treats viewport visibility as an
eligibility boundary.

## 2 Constraints and assumptions

Imposed constraints are Godot 4.7.2, the GL Compatibility renderer, a 1280 by
720 logical viewport, ARM64 Android export, the package identity
`com.ceratopscode.astrotops`, and repository tooling below `scripts/`. Android
updates must reuse the established signing key because Android rejects a
same-package update signed by a different key.

The current implementation assumes one local player, one scene tree, all
targets initially visible, native English text-to-speech availability when
spoken names are desired, and sufficient tablet performance for procedural
2D drawing. The grouped tests verify behavior without requiring text-to-speech
audio output. Maintainers must recheck viewport eligibility and performance
when a camera or off-screen world is introduced.

## 3 System context

The player supplies touch, keyboard, or gamepad input and sees the Godot-rendered
game and hears local audio. Godot supplies rendering, input, configuration,
audio playback, and the host operating system's text-to-speech queue. The game
does not call a network service at runtime and does not hold an account,
credential, or personal profile.

During development and delivery, maintainers use Git, uv, Godot, and Android
Debug Bridge (ADB). GitHub Actions runs the repository-owned validation path.
ADB over USB or Wi-Fi is a deployment boundary, not a game runtime dependency.
The single executable and these simple external boundaries are clearer in
prose than in C4 diagrams, so no C4 view is maintained.

## 4 Solution strategy

One Godot scene hosts a small explicit state machine and composes specialized
Node2D scripts for the ship, celestial bodies, and meteors. Most visual content
is drawn procedurally, while four ship sprites, Trixie, Traxy's six-frame atlas,
the dimmed Milky Way, and a few effects are repository assets. This keeps
iteration fast and avoids a large scene hierarchy, at the cost of a sizeable
central game script.

Gameplay settings use Godot `ConfigFile`; no database or service is necessary.
Automated tests instantiate the real scene, drive controls and state, and use
the Godot renderer for visual evidence. Python owns grouped result reuse,
bounded evidence, artifact identity, and deterministic Android deployment.

## 5 Building blocks

- [`main.tscn`](../main.tscn) and
  [`scripts/main.gd`](../scripts/main.gd) form the application shell. They own
  menu and HUD drawing, the game-state machine, input routing, randomized target
  placement, target contact, mode progression, tractor selection, scores, and
  the rescue and meteor finale.
- [`scripts/audio_controller.gd`](../scripts/audio_controller.gd) owns generated
  interface tones, one-shot effects, delayed English voice discovery, and native
  speech queue submission.
- [`scripts/player_ship.gd`](../scripts/player_ship.gd) owns movement bounds,
  velocity, eight ship styles, cockpit placement, three pilots, and the bounded
  exception that lets the scripted rescue fly offscreen.
- [`scripts/space_target.gd`](../scripts/space_target.gd) defines the common
  capture, extent, and tractor-pull contract shared by stationary and moving
  targets.
- [`scripts/planet.gd`](../scripts/planet.gd) owns each target's recognizable
  rendering, capture radius, paint transition, black-hole treatment, Solar Tour
  marker and timed arrow cue, and explosion animation.
- [`scripts/traxy.gd`](../scripts/traxy.gd) owns Traxy's atlas frame selection,
  flee and corner-escape steering, planet avoidance, captured float and blink,
  collision bounce, suit-accent recoloring, and tow cable rendering.
- [`scripts/meteor.gd`](../scripts/meteor.gd) owns one curved meteor flight and
  reports impact to the game shell.
- [`scripts/regression_tests.gd`](../scripts/regression_tests.gd) is the Godot
  behavior and rendered-surface harness.
- [`scripts/run-tests.py`](../scripts/run-tests.py) selects groups, isolates
  settings, invokes Godot, and assembles applicable results.
- [`scripts/validate-repository.py`](../scripts/validate-repository.py) checks
  repository structure and contracts independently from gameplay tests.
- [`scripts/result_records.py`](../scripts/result_records.py) is the only
  storage owner for portable result records and bounded ignored evidence.
- [`sdlc/sdlc.yml`](../sdlc/sdlc.yml) declares bootstrap, validation, testing,
  packaging, delivery verification, and ADB installation.

## 6 Runtime behavior

The normal state order is Menu, Ready, Countdown, Playing, optional Rescue,
Finale, and Results. Pause temporarily replaces Playing and resumes the prior
state. Any supported input starts a five-step countdown. During play, the ship
moves within bounds, the game checks contact with uncaptured targets, and native
speech requests are submitted in capture order without an application-side
delay.

Space Rush remains the default mode and adds Traxy as a sixteenth target that can
be captured in any order. While uncaptured he steers away from the ship, skims
edges instead of pressing into them, locks a safe corner escape when necessary,
and avoids celestial bodies. Captured Traxy loses the chair, floats with the
approved shocked blink, and reflects from bodies and playfield edges while
rotating slowly clockwise. Only the suit fabric and suit panels adopt the ship
color; Traxy, his helmet glass, tail, and gold hardware retain their source
colors. Solar Tour is an additive menu choice: it keeps the fifteen-body roster,
accepts only the highlighted next body from the Sun outward, shows inward arrows
for the first 2.5 seconds of every new target, and records a separate best time.
Completing the ordered roster adds a Tour Medal to the results panel.
Both modes derive their result layout from the fallback font's actual bounds;
the Solar Tour medal occupies its own row above the elapsed and best times.

The tractor beam selects at most one visible, uncaptured target whose bearing is
eligible for its course-aligned pear-shaped field. It moves that body toward
the ship; it never changes ship heading. The persisted Power setting controls
both range and pull, with diminishing strength growth. Its diagnostic outline
is hidden. Back, Reset, Pause/Resume, and Close in that order within the unlock
window toggles the outline and consumes the sequence; an unmatched Back is
resolved to its normal menu action after the short window.

Marking the last planet in Space Rush freezes the run time, updates the best
score, and enters Rescue. If Traxy was not caught, the game captures and
announces him first. The ship approaches, attaches a visible cable to his suit,
then accelerates through the nearest screen edge with Traxy trailing behind.
Only after both are offscreen does the Finale create one meteor per planet;
Traxy is never a meteor target. Solar Tour proceeds directly from its final body
to the planet-only finale. Each impact starts that body's explosion. After all
impacts, the results view hides the ship and offers replay or menu recovery.
Reset returns the current run to Ready; Back returns to Menu.
The planet pilot draws its far ring arc before the planet body and its near arc
after the face, so the ring visibly wraps around rather than sitting behind it.

## 7 Deployment and operations

Desktop development runs the project directly in Godot. Android packaging
produces `.build/artifacts/android/AstroTops.apk`; build identity and approval
metadata live under `.build/builds/`. The immutable source tag is the build
version, while its resolved commit is traceability metadata. The Gradle export
uses separate adaptive background, foreground, and monochrome launcher layers.

Delivery first verifies saved validation and complete grouped test outcomes
against the exact APK path, length, and SHA-256. ADB installation connects to
the named device, compares the installed base APK hash, installs only changed
bytes, verifies the installed hash, and launches the declared activity. Failed
or semantically empty ADB responses are failures. There is no production
service to monitor; validation JSON, grouped results, build receipts, deployment
receipts, screenshots, and logs provide operational evidence.

## 8 Cross-cutting design

### 8.1 Data and persistence

`user://astrotops.cfg` stores the best time plus tractor-beam enabled and Power
values. [`project.godot`](../project.godot) assigns the `AstroTops` custom user
directory identity. The main scene owns load, validation, update, reset, and
save. Tests replace the path with an isolated runner-owned file. There is no
cloud synchronization, backup contract, or legacy-score migration; changing
the storage identity intentionally starts a distinct store.

Tracked `.test-results/groups/*.json`, `.test-results/tests.json`, and
`.test-results/validation.json` describe the exact source and environment they
tested. Raw `.test-results/evidence/<run-id>/` content is ignored and bounded to
the current run plus at most two predecessors. Build records bind a source tag
to exact artifact bytes. Atomic sibling files prevent partial JSON replacement.

### 8.2 APIs and integrations

Godot Input and `InputEvent` are the player-control interface. `DisplayServer`
owns the native text-to-speech queue. The audio controller retries English
voice discovery at mission setup and again when a capture finds no cached voice,
then submits the name, voice, volume, pitch, rate, utterance identifier, and
`interrupt=false`. Missing voice support still degrades to silent names without
blocking capture. `ConfigFile` is the local persistence interface.

The SDLC contract is [`sdlc/sdlc.yml`](../sdlc/sdlc.yml). Repository helpers
use subprocess argument arrays rather than shell strings. The Android install
interface accepts an ADB executable, device, package, activity, and artifact;
it returns the declared structured receipt or a bounded error.

### 8.3 Security and resilience

AstroTops collects no personal data and has no runtime network trust boundary.
Signing keys and credentials are never committed. The debug keystore is an
external operator-owned secret whose continuity is necessary for in-place
Android upgrades. ADB access is restricted to a user-selected development
device.

Gameplay failure is contained locally: absent settings use safe defaults,
missing text-to-speech remains nonfatal, target placement enforces separation,
and reset reconstructs the run. Result recording rejects dirty portable source,
keeps writes inside the repository, uses atomic replacement, and bounds ignored
evidence. Artifact delivery fails closed when source, tag, bytes, package,
activity, installed hash, or launch confirmation differs.

## 9 Decisions and alternatives

1. **Accepted: one Godot scene with focused responsibility nodes.** Multiple
   levels or a data-driven scene graph would add ceremony before the prototype
   needs it. Audio and speech are split into `scripts/audio_controller.gd`; the
   application shell retains mode, input, orchestration, persistence, and UI.
2. **Accepted: procedural celestial bodies.** Downloaded planet images could be
   more photographic, but procedural drawing supports capture recoloring,
   consistent scaling, and licensing clarity.
3. **Accepted: native queued text-to-speech.** Pre-rendered names would sound
   consistent but add asset and localization lifecycle. The native queue keeps
   names ordered and non-overlapping with no application delay.
4. **Accepted: pull targets rather than steer the ship.** Course correction
   would weaken direct control; moving one eligible target provides assistance
   while preserving player heading.
5. **Accepted: evidence reuse bound to source and artifact identity.** Rerunning
   tests during delivery is slower and can test different bytes. Saved results
   are reusable only while their bindings remain applicable.
6. **Accepted: local steering with locked escape directions for Traxy.** A pure
   away vector predictably pins a fleeing target against edges; a navigation
   grid or pathfinder would add world data and replanning for a small open arena.
   Direct flee, obstacle repulsion, edge tangents, short corner locks, and a
   displacement watchdog keep motion responsive without that lifecycle cost.

## 10 Quality scenarios

| Quality | Stimulus and condition | Expected response and threshold | Verification |
| --- | --- | --- | --- |
| Input parity | A player uses keyboard, gamepad, or touch from Ready and Playing | Each starts or controls the same state transition without an input-specific gameplay advantage | `controls-countdown`, `gameplay-flow` |
| Responsiveness | A visible eligible target enters the tractor field during play | At most one target moves closer in the same update; the ship course is unchanged | `tractor-beam` |
| Escape reliability | Traxy reaches an edge, corner, or nearby planet while fleeing | He chooses a traversable direction, remains in bounds, and continues moving rather than settling in place | `targets` |
| Readability | The game renders at the 1280 by 720 logical viewport | Menu selectors, HUD, labels, pause, results, and countdown remain legible and non-overlapping | `rendered-ui` |
| Icon survival | Android composes adaptive icon layers under a circular launcher mask | Dark space, the diagonal rocket, and the gold ringed planet remain visible; clipped corners are transparent | `rendered-ui` adaptive-icon capture |
| Determinism | Delivery receives a qualified tagged APK | Saved results and the installed APK must match the exact source and SHA-256, or delivery fails | `delivery-lifecycle` |
| Recovery | A run is reset or an unmatched diagnostic Back times out | The normal Ready or Menu state is restored without leaving the hidden field enabled accidentally | `pause-results`, `tractor-beam` |

These are desired thresholds. A passing result applies only to the source,
tools, environment, and optional artifact identity recorded by that run.

## 11 Risks and limitations

- The central game script is still sizeable; new unrelated responsibilities
  should move to focused nodes rather than rebuilding audio or mode logic there.
- Traxy's steering is tuned for the fixed open playfield and stationary bodies;
  moving obstacles or a camera-driven world would require a navigation review.
- Native text-to-speech voice, pronunciation, and latency vary by device. Tests
  verify requests and ordering, not speaker acoustics.
- The fixed logical viewport and all-visible target roster have not yet proven
  camera or large-world behavior. Visibility eligibility is prepared, but a
  future camera needs dedicated behavior and rendered tests.
- The Milky Way image is a generated project asset. Maintainers must preserve
  its generation provenance when replacing or redistributing it.
- Debug signing is appropriate for direct testing, not store release. Losing
  the key prevents updating the installed package without uninstalling it.
- A simulated circular adaptive-icon mask cannot cover every manufacturer mask;
  it is the conservative automated landmark check, not a promise of identical
  launcher presentation on every device.

## 12 Glossary and references

- **Capture:** first ship contact that changes a target toward the selected ship
  color and queues its spoken name.
- **Target:** a capturable celestial body or Traxy in Space Rush.
- **Rescue:** the timed-score-frozen sequence that hooks captured Traxy, tows
  him offscreen, and hands off to the planet-only meteor finale.
- **Tractor field:** the course-aligned pear-shaped eligibility region that can
  pull one visible uncaptured target toward the ship.
- **Qualification:** binding passing validation and grouped tests to exact
  source and, for a candidate, exact package bytes.
- **ResultStore:** the storage owner implemented by
  [`scripts/result_records.py`](../scripts/result_records.py).
- **Adaptive icon:** Android launcher composition from separate background,
  foreground, and optional monochrome layers declared in
  [`export_presets.cfg`](../export_presets.cfg).

The current user-visible requirement map is
[`docs/feature-acceptance.json`](feature-acceptance.json). Asset attributions
and licenses are recorded in
[`THIRD_PARTY_NOTICES.txt`](../THIRD_PARTY_NOTICES.txt).

## 13 Testing and verification

The acceptance map assigns every supported requirement to one or more of ten
groups. Headless Godot groups observe menu, controls, audio requests, tractor
behavior, target models, ship and pilot models, gameplay flow, pause, results,
and persistence. The rendered group captures actual Godot output for menu,
play, pause, countdown, results, cockpit, targets, the hidden tractor field,
Traxy's running, shocked, and cable-tow states, the standalone icon, and the
layered adaptive icon under a circular mask.
Python tests cover result lifecycle, automatic Godot asset-import bootstrapping,
and ADB behavior.

Repository validation is separate from tests. Candidate qualification records
the immutable source tag and exact APK identity. Delivery reuses only applicable
passing records and verifies the artifact instead of rerunning tests. Native
speaker acoustics, manufacturer-specific launcher masks, and future off-screen
camera behavior remain explicit verification gaps.

## 14 Ownership and maintenance

This file at `docs/design.md` is the authoritative design document and is owned
by AstroTops maintainers. Implemented code and configuration outrank this prose
when reconstructing current behavior; `docs/feature-acceptance.json` owns the
testable requirement map. Review this document for every metadata trigger at
the top, and update code, acceptance mapping, tests, delivery contracts, and
design together when one architectural decision changes.

[`docs/result_records.py.tmpl`](result_records.py.tmpl) is for maintainers who
are creating or migrating a Ceratops-compatible repository. It is a reusable
starting point, not imported or executed by AstroTops and not an automatic
source for [`scripts/result_records.py`](../scripts/result_records.py). Its
lifecycle is deliberate adoption: compare the target repository's existing
`scripts/result_records.py` and callers, copy the template into that runtime
path only when appropriate, customize project schemas and integrations, add
behavior tests, and review the change. Each repository must be assessed
separately; never bulk-overwrite existing record owners. After adoption, that
repository's runtime helper is authoritative. Update this template only for a
general reusable contract change, then review adopters individually rather than
silently synchronizing them.
