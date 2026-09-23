# PlaneTops

PlaneTops is a fast top-down arcade prototype. Choose Trixie, an astronaut, or
a little planet as pilot; select one of eight ships and ten paint colors; then
fly through the Sun, eight planets, Moon, Haumea, a black hole, and two
asteroids before the meteor finale.

## Controls

- Keyboard: WASD or arrow keys; P pauses; R resets; M toggles the tractor beam;
  Escape goes back
- Gamepad: left stick or D-pad; A confirms; X toggles the tractor beam; Start
  pauses; B goes back
- Touch or mouse: drag on the left side of the playfield

Choose **Ready Ship**, then press any keyboard key, gamepad button, or tap to
start the animated `5` to `1` countdown. The in-game header also provides Back,
Reset, Pause/Resume, Close, and tractor-beam controls. The beam pulls at most
one uncaptured target whose bearing is close to the ship's course and that is
currently visible on screen. Its slider controls both pull strength and range;
the slider and on/off state are saved between runs. Capturing a target speaks
its English name through the device's text-to-speech voice.

## Run locally

Open this folder in Godot 4.7.2 and run the project. The prototype uses Godot's
GL Compatibility renderer so it can later target Android with the same project.

Trixie's source artwork is stored in `assets/trixie.png`. Ship sprites and sound
effects are CC0 assets from Kenney; planets, the black hole, meteors, and visual
effects are drawn procedurally at runtime. The Milky Way source image is stored
in `assets/milky_way_background.jpg` and is rotated, cropped, and dimmed by the
game at runtime.

## Prototype builds

- Windows: `build/windows/PlaneTops.exe`
- Android: `build/android/PlaneTops.apk`

Install Godot's Android build template from
**Project > Install Android Build Template** before exporting Android. PlaneTops
uses the Gradle exporter so Android's themed launcher icon is packaged correctly.

The APK is a debug-signed ARM64 prototype intended for direct testing, not a
Play Store release.

Android updates must reuse the same persistent Godot debug keystore. A regular
Godot installation keeps it under `%APPDATA%/Godot/keystores`; a self-contained
editor must be configured with that same key before export. Losing or replacing
the private key requires uninstalling the existing Android package before a new
signature can be installed.
