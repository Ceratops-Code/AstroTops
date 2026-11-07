package io.github.ceratops_code.boboboard.godot

import android.Manifest
import android.content.pm.PackageManager
import io.github.ceratops_code.boboboard.BoboBoardClient
import io.github.ceratops_code.boboboard.BoardSnapshot
import org.godotengine.godot.Godot
import org.godotengine.godot.plugin.GodotPlugin
import org.godotengine.godot.plugin.SignalInfo
import org.godotengine.godot.plugin.UsedByGodot

/** Thin engine boundary. Only this adapter knows Godot; the board library stays reusable. */
class BoboBoardPlugin(godot: Godot) : GodotPlugin(godot) {
    private var client: BoboBoardClient? = null
    private var pendingConnect = false
    private var destroyed = false
    private var foreground = true
    private var connectAfterResume = false
    private val permissions = arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
    override fun getPluginName() = "BoboBoard"
    override fun getPluginSignals() = setOf(SignalInfo("board_state_changed", String::class.java))
    private fun emit(state: BoardSnapshot) {
        if (destroyed) return
        emitSignal("board_state_changed", state.toJson())
    }
    @UsedByGodot fun connectToBoBoBoard() {
        activity?.runOnUiThread {
            if (destroyed) return@runOnUiThread
            if (!foreground) { connectAfterResume = true; return@runOnUiThread }
            val host = activity ?: return@runOnUiThread
            if (permissions.any { host.checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }) {
                if (!pendingConnect) {
                    pendingConnect = true
                    emit(BoardSnapshot("permission", "Allow Nearby devices to connect to BoBo"))
                    host.requestPermissions(permissions, 7341)
                }
                return@runOnUiThread
            }
            try {
                val board = client ?: BoboBoardClient(host, ::emit).also { client = it }
                board.connectToBoBoBoard()
            } catch (error: Exception) { emit(BoardSnapshot("error", "BoBo setup failed: " + error.message)) }
        }
    }
    @UsedByGodot fun disconnectFromBoBoBoard() {
        activity?.runOnUiThread {
            pendingConnect = false
            connectAfterResume = false
            client?.disconnectFromBoBoBoard() ?: emit(BoardSnapshot())
        }
    }
    @UsedByGodot fun setCalibrationJson(text: String) {
        activity?.runOnUiThread {
            try {
                val host = activity ?: return@runOnUiThread
                val board = client ?: BoboBoardClient(host, ::emit).also { client = it }
                board.setCalibrationJson(text)
            } catch (error: Exception) { emit(BoardSnapshot("error", "BoBo calibration failed: " + error.message)) }
        }
    }
    private fun calibrationAction(action: (BoboBoardClient) -> Unit) {
        activity?.runOnUiThread {
            val board = client ?: return@runOnUiThread
            try { action(board) }
            catch (error: Exception) {
                emit(board.snapshot.copy(calibration = board.snapshot.calibration.copy(
                    event = "action_failed", message = "BoBo calibration action failed: " + error.message)))
            }
        }
    }
    @UsedByGodot fun beginBoardCalibration() = calibrationAction { it.beginBoardCalibration() }
    @UsedByGodot fun selectBoardCalibrationPose(pose: String) = calibrationAction { it.selectBoardCalibrationPose(pose) }
    @UsedByGodot fun captureBoardCalibrationPose() = calibrationAction { it.captureBoardCalibrationPose() }
    @UsedByGodot fun cancelBoardCalibration() = calibrationAction { it.cancelBoardCalibration() }
    @UsedByGodot fun saveBoardCalibration() = calibrationAction { it.saveBoardCalibration() }
    @UsedByGodot fun saveBoardCenter() = calibrationAction { it.saveBoardCenter() }
    @UsedByGodot fun setBoardSensitivityPercent(control: String, percent: Int) = calibrationAction { it.setBoardSensitivityPercent(control, percent) }
    @UsedByGodot fun saveBoardSensitivity() = calibrationAction { it.saveBoardSensitivity() }
    @UsedByGodot fun restoreImportedBoardCalibration() = calibrationAction { it.restoreImportedBoardCalibration() }
    override fun onMainRequestPermissionsResult(code: Int, names: Array<out String>, results: IntArray) {
        if (code != 7341 || !pendingConnect) return
        pendingConnect = false
        if (results.isNotEmpty() && results.all { it == PackageManager.PERMISSION_GRANTED }) connectToBoBoBoard()
        else emit(BoardSnapshot("error", "Allow Nearby devices in Android app settings, then tap Connect."))
    }
    override fun onMainPause() { foreground = false; client?.disconnectFromBoBoBoard() }
    override fun onMainResume() {
        foreground = true
        if (connectAfterResume) { connectAfterResume = false; connectToBoBoBoard() }
    }
    override fun onMainDestroy() { destroyed = true; pendingConnect = false; client?.close(); client = null }
}
