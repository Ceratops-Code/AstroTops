# AstroTops

AstroTops is a fast top-down arcade prototype. Choose Trixie, an astronaut, or
a little planet as pilot; select one of eight ships and ten paint colors; then
fly through the Sun, eight planets, Moon, Pluto, Haumea, a black hole, and two
asteroids before the meteor finale. Space Rush adds Traxy, a mischievous
spacesuited T-rex in a thruster chair, as a sixteenth moving target. Solar Tour
keeps the fifteen-body roster and highlights and enforces the next target from
the smallest body to the largest, then awards a Tour Medal. Its first guidance
arrows appear one second after the launch countdown ends.

## Controls

- Keyboard: WASD or arrow keys; P pauses; R resets; M toggles the tractor beam;
  T changes mode on the menu; Escape goes back
- Gamepad: left stick or D-pad; A confirms; X toggles the tractor beam; Start
  pauses; Y changes mode on the menu; B goes back
- Touch or mouse: drag on the left side of the playfield
- BoBo board on Android: open **BoBo Board** at the upper left, choose
  **Connect to BoBo**, then **Test board** to steer
  the ship without starting a mission. **Disconnect BoBo** fully releases the
  connection and keeps it off until Connect is pressed again. WobblePad and
  Shizuku are not required. The saved board calibration is bundled; Android
  asks for Nearby devices permission when needed. Lost tilt pauses play, and
  Connect/Disconnect remain available in the mission header.
  **Calibrate board** guides five three-second poses and saves an acceptable
  profile for that board. Cancel or disconnect discards the draft; **Restore
  imported default** restores the original profile. The sidebar remembers its
  open/closed state. The calibration screen also has four sensitivity sliders,
  center dead zone, and live preview. **Save sensitivity** keeps the existing
  poses, so changing the feel does not require recapturing them. The main-menu
  **Exit** button closes the game.

Choose **Launch Mission**, then press any keyboard key, gamepad button, or tap to
start the animated `5` to `1` countdown. The in-game header also provides Back,
Reset, Pause/Resume, Close, and tractor-beam controls. The beam pulls at most
one uncaptured, currently visible target inside a course-aligned pear-shaped
field. The field is wider close to the ship and tapers over its shortened
range. Its diagnostic outline is hidden by default; pressing Back, Reset,
Pause/Resume, then Close in sequence toggles it without performing those four
actions. The slider controls both pull strength and range, with pull strength
rising on a gentler curve; its value and on/off
state are saved between runs. Captured names use the device's English
text-to-speech voice at normal speed, one at a time. Traxy flees the ship without
camping in corners; one overhead chair sprite turns smoothly toward his escape
vector while two independent rear thrusters pulse and bias through turns.
Catching him produces a white cloud and a short nonverbal
poof before his name is spoken; his label and only his suit adopt the ship
color. He then floats with a shocked blink, rotates slowly clockwise, and
bounces off planets and edges. After every planet and Traxy are explicitly
caught, the ship stages between him and the farthest corner, launches and
latches a visible animated
hook, then tows him at 70% speed toward the farthest corner and offscreen before
the planet-only meteor finale.
The countdown uses five short beeps followed by a sharper, louder final tone
derived from the beep at one-quarter frequency and twice its duration. Audio
generation, effects, and speech are owned by `scripts/audio_controller.gd`.

## Run locally

Open this folder in Godot 4.7.2 and run the project. The prototype uses Godot's
GL Compatibility renderer so it can later target Android with the same project.

The authoritative architecture and lifecycle description is in
[`docs/design.md`](docs/design.md).

The standalone Android board library and Godot adapter are in
[`addons/bobo_board`](addons/bobo_board/README.md). Other Android applications
can reuse the board library without Godot or any AstroTops game code. It requires
Android 12 or newer. Android export builds its libraries automatically;
`uv run --project scripts --locked python scripts/build_board_module.py` builds
only the reusable module.

Trixie's source artwork is stored in `assets/trixie.png`; Traxy's six-frame
source atlas is `assets/traxy.png`, with one overhead chair frame and two shocked
frames selected at runtime. Chair exhaust is drawn separately in code. Ship
sprites and sound effects are CC0 assets from Kenney; planets, the black hole,
meteors, and visual effects are drawn procedurally at runtime. The generated
Milky Way image is stored in `assets/milky_way_background.png` and is rotated,
cropped, and dimmed by the game at runtime.

## Prototype builds

- Windows: `.build/artifacts/windows/AstroTops.exe`
- Android: `.build/artifacts/android/AstroTops.apk`

The repository provisions its pinned Godot 4.7.2 editor automatically for
validation, tests, and export when no matching `GODOT_EXECUTABLE` or `godot` on
`PATH` is available. Android export also provisions only the verified 214 MB
Android source member from Godot's official template bundle and installs a
missing project build template automatically. AstroTops uses the Gradle exporter
so Android's themed launcher icon is packaged correctly. The shipping validation
also requires a JDK and Android SDK, creates a disposable debug export, runs the
template's Gradle lint task, and removes the validation-only APK before remote
shipping can begin.

The APK is a debug-signed ARM64 prototype intended for direct testing, not a
Play Store release.

Android updates must reuse the same persistent Godot debug keystore. A regular
Godot installation keeps it under `%APPDATA%/Godot/keystores`; a self-contained
editor must be configured with that same key before export. Losing or replacing
the private key requires uninstalling the existing Android package before a new
signature can be installed.

## Automated gameplay tests

`scripts/run-tests.py` owns twelve persistent groups covering menus, controls,
countdown, speech and tones, tractor-beam behavior, targets, ships and pilots,
pause/results, Android delivery, direct BoBo input, and rendered UI. The
acceptance map is
`docs/feature-acceptance.json`.

Run missing or affected groups; the helper resolves Godot 4.7.2 first:

```powershell
uv run --project scripts --locked scripts/run-tests.py --no-record
```

`scripts/run-tests.py --prepare-godot` performs only the editor preflight.
`scripts/run-tests.py --validate-android-build` checks `JAVA_HOME` or `java` on
`PATH`, checks `ANDROID_HOME` or `ANDROID_SDK_ROOT`, parses and exports the
project, and runs Gradle lint.
Editor and Android-template downloads use pinned official sizes and SHA-256
hashes, publish to separate versioned caches atomically, remove interrupted
helper-owned files, and retain the current version plus at most two
predecessors. The default root is the operating system's user cache under
`Ceratops/AstroTops/tools`; set `ASTROTOPS_TOOL_CACHE` to relocate it. Set
`ASTROTOPS_ANDROID_SOURCE_TEMPLATE` to an exact matching local source ZIP for
offline Android builds. `--godot` remains the explicit per-run editor override,
followed by `GODOT_EXECUTABLE` and a matching executable on `PATH`. No
system-wide installer or persistent `PATH` change is made. An existing invalid
or customized `android` directory is preserved and reported instead of replaced.

The runner first asks Godot to import project assets, so a fresh checkout does
not require opening the editor before tests.

Pass `--group <group-id>` to select a group. A matching pass is reused even for
an explicitly selected group; `--fresh` explicitly requests execution again.
With caller-supplied result identities, a fresh run needs a new result ID/path;
an accepted identity remains immutable.
The runner updates affected groups, preserves applicable passing results, and recalculates
`.test-results/tests.json`. Tracked JSON records are bound to source bytes,
tools, environment, and an optional exact artifact; screenshots and raw logs
are retained in the ignored `.test-results/evidence/` directory.
After artifact qualification, ordinary lifecycle test gates reuse that artifact
binding only while the source, path, length, and SHA-256 still match. Missing or
changed bytes make the qualification inapplicable.

SDLC repository gates use `--no-record` to keep tracked acceptance records
unchanged during CI and promotion. Explicit recorded runs still own those
records for artifact qualification. Both modes retain actual outcomes in the
shared Ceratops store under the Git common directory at
`ceratops/results/repository-checks/<worktree-id>/check_results.json`.
The SDLC declarations provide product inputs, separate check-only inputs,
dependency locks, relevant environment and tools. The shared executor supplies
the result/candidate/check identities and qualification level. The runner writes
actual outcomes using `ceratops-repository-check-result.v1`; original group
executions, source and check versions survive reuse. New alpha results cannot
satisfy beta, rc or final gates. The same shared file owns current game-group
outcomes and repository-check outcomes; there is no separate local cache owner.
Reuse matches owned inputs, dependency locks, runtime/build scope and
artifact identity.
Inputs are checked again after execution; changed inputs cannot receive a pass.
A latest failed/running outcome cannot reuse an older pass. New calls execute
missing work from current inputs rather than resuming saved steps. Malformed
local outcomes block the call and retain their bytes for diagnosis. Serialize
runner calls in each worktree. The shared current file is bounded to 64 MiB;
repository-check results additionally obey the shared executor's record limit.
Its writer removes the fixed in-process file at startup and after replacement.
Evidence retains current group runs plus two unreferenced runs, at most fifteen
folders for the twelve-group inventory. Retiring the worktree removes its local
outcomes; portable release records remain separate.

Both test and repository-check runners expose `--describe-test-results` and
the shared five-argument result interface. Their public protocol probes cover
running output, canonical completion, exact reuse, conflicts, interruptions and
explicit repair of never-accepted malformed output. The maintained writer lives
in `scripts/result_records.py`; adopting it adds the locked `packaging` dependency.
CI uses a published action revision that supports this protocol.

Shared check receipts and qualification levels are connected. Artifact receipts
and receipt-driven release consumption still require the Kit's planned public
Build/Deploy routing. Current package build and installation keep their existing
source/tag contract; they do not claim completed artifact-receipt acceptance.

Repository validation separately updates `.test-results/validation.json` on
clean committed source. Delivery requires both that applicable validation
record and the complete gameplay result before checking the exact artifact.
