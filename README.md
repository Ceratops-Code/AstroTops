# AstroTops

AstroTops is a fast top-down arcade prototype. Choose Trixie, an astronaut, or
a little planet as pilot; select one of eight ships and ten paint colors; then
fly through the Sun, eight planets, Moon, Pluto, Haumea, a black hole, and two
asteroids before the meteor finale. Space Rush adds Traxy, a mischievous
spacesuited T-rex in a thruster chair, as a sixteenth moving target. Solar Tour
keeps the fifteen-body roster and highlights and enforces the next target from
the Sun outward, then awards a Tour Medal.

## Controls

- Keyboard: WASD or arrow keys; P pauses; R resets; M toggles the tractor beam;
  T changes mode on the menu; Escape goes back
- Gamepad: left stick or D-pad; A confirms; X toggles the tractor beam; Start
  pauses; Y changes mode on the menu; B goes back
- Touch or mouse: drag on the left side of the playfield

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
camping in corners. Catching him produces a white cloud and a short nonverbal
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

Trixie's source artwork is stored in `assets/trixie.png`; Traxy's six-frame
directional and shocked atlas is `assets/traxy.png`. Ship sprites and sound
effects are CC0 assets from Kenney; planets, the black hole, meteors, and visual
effects are drawn procedurally at runtime. The generated Milky Way image is
stored in `assets/milky_way_background.png` and is rotated, cropped, and dimmed
by the game at runtime.

## Prototype builds

- Windows: `.build/artifacts/windows/AstroTops.exe`
- Android: `.build/artifacts/android/AstroTops.apk`

Install Godot's Android build template from
**Project > Install Android Build Template** before exporting Android. AstroTops
uses the Gradle exporter so Android's themed launcher icon is packaged correctly.

The APK is a debug-signed ARM64 prototype intended for direct testing, not a
Play Store release.

Android updates must reuse the same persistent Godot debug keystore. A regular
Godot installation keeps it under `%APPDATA%/Godot/keystores`; a self-contained
editor must be configured with that same key before export. Losing or replacing
the private key requires uninstalling the existing Android package before a new
signature can be installed.

## Automated gameplay tests

`scripts/run-tests.py` owns ten persistent groups covering menus, controls,
countdown, speech and tones, tractor-beam behavior, targets, ships and pilots,
pause/results, Android delivery, and rendered UI. The acceptance map is
`docs/feature-acceptance.json`.

Run the whole suite with Godot 4.7.2 on `PATH`:

```powershell
uv run --locked scripts/run-tests.py --fresh
```

The runner first asks Godot to import project assets, so a fresh checkout does
not require opening the editor before tests.

Pass `--group <group-id>` for a targeted rerun. The runner updates that group,
preserves only applicable passing results for other groups, and recalculates
`.test-results/tests.json`. Tracked JSON records are bound to source bytes,
tools, environment, and an optional exact artifact; screenshots and raw logs
are retained in the ignored `.test-results/evidence/` directory.
After artifact qualification, ordinary lifecycle test gates reuse that artifact
binding only while the source, path, length, and SHA-256 still match. Missing or
changed bytes make the qualification inapplicable.

Repository validation separately updates `.test-results/validation.json` on
clean committed source. Delivery requires both that applicable validation
record and the complete gameplay result before checking the exact artifact.
