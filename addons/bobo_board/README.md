# BoBo Board module

This module is for Android and Godot developers who need direct tilt input from
a compatible BoBo Wobbly board. It contains a reusable Android library and a thin
Godot 4.7 adapter. Neither WobblePad nor Shizuku is a runtime dependency.

## Contents and requirements

- Native Android library: native/board, package
  io.github.ceratops_code.boboboard.
- Godot Android adapter: native/godot, singleton BoboBoard.
- Godot facade: read_board_input.gd, class BoboBoardInput.
- Android 12/API 31 or newer, Bluetooth LE, and Nearby devices permission.
- Build prerequisites: JDK 17, Android SDK 36, ANDROID_HOME or
  ANDROID_SDK_ROOT. The pinned Gradle wrapper downloads Gradle when absent.

The Bluetooth layer uses Nordic Android BLE Library 2.11.0. The application
owns only its own scan and GATT connection. It never toggles Bluetooth, stops
another application, creates a virtual controller, or asks for elevated access.

## Use in AstroTops

Open the BoBo Board toggle at the upper left. The sidebar starts collapsed and
remembers its open/closed state in the host game settings. Its container layout
keeps status, buttons, and calibration source separated as labels wrap.
Choose Connect to BoBo, then Test board to steer the real ship without a
mission, countdown, targets, or score. Preview and flight use the same screen
coordinates and movement function. Disconnect clears input, finishes local
connection cleanup, and stays disconnected until another Connect command.
Connect is disabled until release finishes, including cleanup after a tilt error.

A lost or stale tilt stream stops the ship and pauses an active mission.
Reconnect is available in the mission header; Resume remains a separate action.
Leaving the foreground releases the board, with no automatic reconnect on return.
If another application holds the board, disconnect there before connecting here.

## Reuse in another Android application

Copy native/board and include it as an Android library module. Its public
BoboBoardClient takes a Context and a callback receiving BoardSnapshot.
Call connectToBoBoBoard and disconnectFromBoBoBoard on the main thread.
Call close when the host closes, and disconnect when it leaves the foreground.
Obtain BLUETOOTH_SCAN and BLUETOOTH_CONNECT runtime permissions before Connect.

BoardSnapshot reports status, message, screen-coordinate tilt, freshness,
battery when available, and a sequence that changes only for accepted packets.
Ready requires an accepted packet and calibration; a transport connection alone
does not qualify. Scanning, connection, and first-packet waits have finite
deadlines. A tilt stream older than one second clears movement and closes the
connection. Repeated commands and callbacks from retired connections are safe.

No Godot class or AstroTops asset appears in native/board. Its AAR depends on
no.nordicsemi.android:ble:2.11.0. A receiving Android build must declare that
dependency as well when importing the AAR directly.

## Reuse in another Godot project

Copy this whole addon and enable plugin.cfg in the editor. Build the native
libraries before exporting Android. Use Gradle export with a minimum SDK of 31.
The facade can be instantiated as a Node; connect board_state_changed and
board_input_lost, call connect_board or disconnect_board, and read movement only
while is_ready returns true. Its optional backend property supports host-side
integration tests. Desktop builds retain normal controls and report the direct
Bluetooth backend as unavailable.

From native, the Gradle tasks :board:assembleDebug, :board:assembleRelease,
:godot:assembleDebug and :godot:assembleRelease produce the two libraries.
In this repository, scripts/build_board_module.py publishes their current AARs
for the export plugin. Android export calls that helper automatically.

## Calibration

The bundled profile is a direct import of the owner's saved WobblePad
calibration: 84 nine-field samples across CENTER, LEFT, RIGHT, UP and DOWN,
directional sensitivity 1.43, and radial dead zone 0.11. The Bluetooth address
and other app settings are excluded. This profile is the default on every fresh
client, so WobblePad does not have to be installed to obtain it.

The profile was measured on one physical board and is not a universal calibration
claim for every hardware revision. The menu preview should be used to check a
different board. Board settings guides Center, Left, Right, Forward and Backward
poses. Each capture takes three seconds of live notifications. Pose buttons can
recapture individual steps. Save becomes available only after every pose and the
complete fit pass; the current mapper stays unchanged until that explicit Save.
Cancel, backgrounding, lost tilt, or disconnect discards unsaved captures.
Restore imported default replaces only the connected board's saved override.

The same screen exposes WobblePad's four directional sensitivity controls
(50–200%) and center dead zone (0–30%), initially 143% and 11% from the import.
Higher sensitivity reaches full input with less tilt. Dead zone measures a
fraction of calibrated tilt before sensitivity, so increasing sensitivity cannot
shrink the center zone. Entering the zone clears filter history and returns exact
zero input immediately. The live dot and X/Y values use the module's mapper, while
game movement stays zero during calibration. Sliders affect a draft until saved.
Save sensitivity keeps the current accepted pose samples and does not require
any new captures. It stays on the screen and preserves unfinished captures.
Godot hosts must enable touchscreen mouse emulation for the standard GUI sliders
and buttons; hosts that also process raw touch must skip its emulated mouse copy
in their gameplay handler to avoid performing one action twice.
Save calibration saves all five accepted new poses with the draft controls.
Cancel discards only unsaved changes; a successful sensitivity save remains saved.
Capture freezes control edits. Restore resets both poses and controls.

Native hosts can call beginBoardCalibration, selectBoardCalibrationPose,
captureBoardCalibrationPose, cancelBoardCalibration, saveBoardCalibration and
restoreImportedBoardCalibration. setBoardSensitivityPercent accepts a control
name (LEFT, RIGHT, UP, DOWN or DEAD_ZONE) and an integer percent;
saveBoardSensitivity persists it for the connected board. Snapshot calibration
data exposes the module-owned control labels, bounds, draft values, live preview,
selected pose, completed poses, countdown, save readiness and action failures.
BoardSnapshot.toJson provides the engine-neutral wire format. Godot
hosts can use the corresponding facade methods and its optional sidebar and
calibration-panel factories; those widgets contain no AstroTops game logic.

Hosts can supply an in-memory profile with setCalibrationJson; the
format is demonstrated by board/src/main/assets/bobo_board/default_calibration.json.
The module rejects missing poses, malformed/nonfinite values, insufficient or
unsteady tilts, overlapping axes, and a center outside the opposite tilts before
replacing the active mapper. A saved per-board profile takes precedence over the
fallback profile when connecting. New captures retain the active sensitivity
and dead-zone settings unless the user changes their draft. Adjusting controls
reuses accepted pose geometry; it does not fit unchanged samples again.

## Outputs and checks

The native client owns filesDir/bobo_board/calibrations in its host application.
It stores one current JSON per board under a SHA-256 digest of the board address;
the profile contains no raw address. Save and Restore inspect current content
before writing. Android AtomicFile replaces the current file only with a complete
profile; the active mapper changes after the stored bytes report success.
An interrupted write leaves either complete profile, never a partial one. A
fresh call checks current storage again, including after a lost acknowledgement.
Startup and each storage operation recover legacy backups and discard only known
orphan staging files. Successful writes retain one current file per board and
remove temporary recovery files. The store serializes clients in one application
process; multi-process hosts need their own store implementation. No operational
logs are written. Unsaved capture data lives only in bounded memory buffers.

Gradle owns native/.gradle and native/.build as local incremental build caches.
Each module/variant has one current output directory. The Python build helper
owns .artifacts: one current AAR per library and variant, exact temporary siblings
removed at startup/publication, and one last-build log limited to 2 MiB.
A failed build blocks game export. These locations are disposable and ignored;
they are not part of a reusable source package.

The repository test runner's board-module group runs JVM tests for the imported
profile, packet decoding, filtering, repeated commands, interrupted scan/connect/
release boundaries, late callbacks, stale packets, and timeouts, plus interrupted
AAR copy/publication and fresh build calls after failure. Calibration cases cover
every capture boundary, rejected poses, single-pose recapture, per-board scope,
fresh clients, and interruptions before/after Save and Restore effects. The
same suite covers sensitivity direction, ranges, preview isolation, cancelled
drafts, separate saves and interruptions on both sides of their storage effect.
The
controls-countdown group exercises the Godot facade, menu preview, flight input,
pause and explicit reconnect/resume. The board-ui group renders the board menu
and mission-free preview with the real ship. Physical BLE behavior on the target
tablet still requires a real-board check of the resulting Android build.

## Provenance

The packet format and calibration algorithm derive from WobblePad, available
under Apache License 2.0. LICENSE preserves that license for those portions.
Original surrounding code follows the repository license. Nordic BLE and the
Gradle wrapper retain their Apache 2.0 licenses; Godot retains its MIT license.
This is an unofficial integration, independent of BO&BO Ltd.
