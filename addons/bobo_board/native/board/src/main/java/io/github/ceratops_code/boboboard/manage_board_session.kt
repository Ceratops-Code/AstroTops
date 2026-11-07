package io.github.ceratops_code.boboboard

import org.json.JSONArray
import org.json.JSONObject

/** A radio owns its scan and GATT resources, and completes release only after closing
 * its local client. A false release acknowledgement means peripheral confirmation
 * timed out; it never means resources should be kept open.
 */
interface BoardRadio {
    fun scanForBoard(found: (String) -> Unit, failed: (String) -> Unit)
    fun stopScanning()
    fun connectToBoard(address: String, events: BoardRadioEvents)
    fun releaseBoard(released: (Boolean) -> Unit)
}
interface BoardRadioEvents {
    fun ready()
    fun packet(bytes: ByteArray)
    fun battery(percent: Int)
    fun failed(reason: String)
}
/** A host store inspects current content before each atomic replacement. */
interface BoardCalibrationStore {
    fun readBoardCalibration(address: String): BoardCalibration?
    fun saveBoardCalibration(address: String, profile: BoardCalibration)
}
data class BoardCalibrationStatus(
    val active: Boolean = false, val pose: String = "CENTER", val captured: List<String> = emptyList(),
    val capturing: Boolean = false, val remainingMs: Long = 0, val canSave: Boolean = false,
    val message: String = "", val event: String = "",
    val sensitivity: BoardSensitivity = BoardSensitivity(), val canSaveSensitivity: Boolean = false,
    val previewTilt: BoardTilt = BoardTilt(), val canSaveCenter: Boolean = false,
)
data class BoardSnapshot(
    val status: String = "disconnected", val message: String = "BoBo disconnected",
    val tilt: BoardTilt = BoardTilt(), val fresh: Boolean = false, val battery: Int = -1,
    val sequence: Long = 0,
    val calibrationSource: String = "Imported default", val calibration: BoardCalibrationStatus = BoardCalibrationStatus(),
) {
    /** Engine-neutral wire format, including the module-owned sensitivity controls. */
    fun toJson(): String = JSONObject().put("status", status).put("message", message)
        .put("x", tilt.x).put("y", tilt.y).put("fresh", fresh).put("battery", battery).put("sequence", sequence)
        .put("calibration_source", calibrationSource)
        .put("calibration", JSONObject().put("active", calibration.active).put("pose", calibration.pose)
            .put("captured", JSONArray(calibration.captured)).put("capturing", calibration.capturing)
            .put("remaining_ms", calibration.remainingMs).put("can_save", calibration.canSave)
            .put("message", calibration.message).put("event", calibration.event)
            .put("can_save_sensitivity", calibration.canSaveSensitivity).put("can_save_center", calibration.canSaveCenter)
            .put("preview_x", calibration.previewTilt.x).put("preview_y", calibration.previewTilt.y)
            .put("sensitivity_controls", JSONArray(BoardSensitivityControl.entries.map { control ->
                JSONObject().put("id", control.name).put("label", control.label)
                    .put("minimum", control.minimumPercent).put("maximum", control.maximumPercent)
                    .put("percent", calibration.sensitivity.percent(control))
            }))).toString()
}

/** Engine-independent connection owner. All calls belong on one host thread.
 * Repeated commands inspect current state. Generations reject callbacks from retired
 * scans/connections; they are not persisted recovery checkpoints. Every failure
 * clears movement and closes owned resources before another Connect can proceed.
 */
class BoboBoardSession(
    private val radio: BoardRadio, profile: BoardCalibration,
    private val nowMs: () -> Long, private val changed: (BoardSnapshot) -> Unit,
    private val store: BoardCalibrationStore? = null,
) {
    var snapshot = BoardSnapshot(); private set
    private var mapper = BoardTiltMapper.fromCalibration(profile)
    private var wanted = false
    private var generation = 0
    private var lastPacket = -1L
    private var deadline = 0L
    private val importedDefault = profile
    private var fallbackProfile = profile
    private var activeProfile = profile
    private var boardAddress: String? = null
    private var pendingCalibration: BoardCalibrationCapture? = null
    private var previewMapper: BoardTiltMapper? = null
    private var previewTilt = BoardTilt()

    fun connectToBoBoBoard() {
        wanted = true
        if (snapshot.status == "releasing" || snapshot.status in listOf("scanning", "connecting", "waiting", "ready", "calibrating")) return
        startScan()
    }
    private fun publish(value: BoardSnapshot) { snapshot = value; changed(value) }
    private fun startScan() {
        val token = ++generation
        pendingCalibration = null; boardAddress = null
        mapper.reset(); lastPacket = -1; deadline = nowMs() + 12000
        publish(BoardSnapshot("scanning", "Searching for BoBo"))
        try {
            radio.scanForBoard({ address ->
                if (token == generation && wanted && snapshot.status == "scanning") {
                    radio.stopScanning()
                    boardAddress = address
                    var source = if (fallbackProfile.hasSameValues(importedDefault)) "Imported default" else "Supplied calibration"
                    val (selected, fitted) = try {
                        val saved = store?.readBoardCalibration(address)
                        if (saved != null) source = if (saved.hasSameValues(importedDefault)) "Imported default" else "Saved for this board"
                        val chosen = saved ?: fallbackProfile
                        chosen to BoardTiltMapper.fromCalibration(chosen)
                    } catch (_error: Exception) {
                        source = "Imported default (saved profile unavailable)"
                        importedDefault to BoardTiltMapper.fromCalibration(importedDefault)
                    }
                    activeProfile = selected
                    mapper = fitted
                    deadline = nowMs() + 15000
                    publish(BoardSnapshot("connecting", "Connecting to BoBo", calibrationSource = source))
                    try { radio.connectToBoard(address, events(token)) }
                    catch (error: Exception) { fail("BoBo connection failed: " + error.message) }
                }
            }, { reason -> if (token == generation) fail(reason) })
        } catch (error: Exception) { fail("BoBo scan failed: " + error.message) }
    }
    private fun events(token: Int) = object : BoardRadioEvents {
        override fun ready() {
            if (token != generation || !wanted) return
            deadline = nowMs() + 5000
            publish(snapshot.copy(status = "waiting", message = "Waiting for live BoBo tilt", tilt = BoardTilt(), fresh = false))
        }
        override fun packet(bytes: ByteArray) {
            if (token != generation || !wanted || snapshot.status !in listOf("waiting", "ready", "calibrating")) return
            val values = BoardPacketParser.parse(bytes) ?: return
            lastPacket = nowMs()
            val capture = pendingCalibration
            if (capture != null) capture.acceptPacket(values, lastPacket)
            previewTilt = if (capture != null) previewMapper?.update(values, lastPacket * 1_000_000) ?: BoardTilt() else BoardTilt()
            val tilt = if (capture == null) mapper.update(values, lastPacket * 1_000_000) else BoardTilt()
            publish(snapshot.copy(status = if (capture == null) "ready" else "calibrating",
                message = if (capture == null) "BoBo ready" else "BoBo calibration active",
                tilt = tilt, fresh = true, sequence = snapshot.sequence + 1,
                calibration = calibrationStatus()))
        }
        override fun battery(percent: Int) {
            if (token == generation && percent in 0..100) publish(snapshot.copy(battery = percent))
        }
        override fun failed(reason: String) { if (token == generation) fail(reason) }
    }
    fun checkTiltFreshness() {
        val now = nowMs()
        when {
            snapshot.status in listOf("ready", "calibrating") && now - lastPacket > 1000 -> fail("BoBo tilt stopped. Current calibration kept. Tap Connect to reconnect.")
            snapshot.status == "waiting" && now >= deadline -> fail("No BoBo tilt received. Check the board and reconnect.")
            snapshot.status == "scanning" && now >= deadline -> fail("BoBo not found. Power on the board and tap Connect.")
            snapshot.status == "connecting" && now >= deadline -> fail("BoBo connection timed out. Close other board apps and reconnect.")
        }
        val capture = pendingCalibration
        if (capture != null && capture.capturing) {
            val finished = capture.finishCaptureIfDue(now)
            if (finished && capture.acceptedMapper != null) previewMapper = capture.acceptedMapper!!.withSensitivity(capture.sensitivity)
            publish(snapshot.copy(calibration = calibrationStatus(if (finished) "captured" else "capturing")))
        }
    }
    fun disconnectFromBoBoBoard() {
        wanted = false
        if (snapshot.status == "releasing" || snapshot.status == "disconnected") return
        release(false, "BoBo disconnected")
    }
    fun replaceCalibration(profile: BoardCalibration) {
        val replacement = BoardTiltMapper.fromCalibration(profile)
        fallbackProfile = profile; activeProfile = profile; pendingCalibration = null
        mapper = replacement
        if (snapshot.status in listOf("ready", "calibrating")) {
            lastPacket = -1; deadline = nowMs() + 5000
            publish(snapshot.copy(status = "waiting", message = "Waiting for tilt with the new calibration", tilt = BoardTilt(), fresh = false,
                calibrationSource = "Supplied calibration", calibration = BoardCalibrationStatus()))
        }
    }
    private fun liveTilt() = lastPacket >= 0 && nowMs() - lastPacket <= 1000
    private fun calibrationStatus(event: String? = null, message: String? = null): BoardCalibrationStatus {
        val capture = pendingCalibration ?: return BoardCalibrationStatus(
            sensitivity = activeProfile.sensitivity,
            event = event ?: snapshot.calibration.event, message = message ?: snapshot.calibration.message)
        if (message != null) capture.reportActionFailure(message)
        return BoardCalibrationStatus(true, capture.pose.name, capture.captured.map { it.name }, capture.capturing,
            capture.remainingMs(nowMs()), capture.canSaveCalibration,
            message ?: capture.message, event ?: snapshot.calibration.event, capture.sensitivity,
            capture.sensitivity != activeProfile.sensitivity && !capture.capturing, previewTilt, capture.canSaveCenter)
    }
    fun beginBoardCalibration() {
        if (pendingCalibration != null) return
        if (snapshot.status != "ready" || !liveTilt()) {
            publish(snapshot.copy(message = "Connect and wait for live tilt before calibrating.")); return
        }
        mapper.reset()
        pendingCalibration = BoardCalibrationCapture(activeProfile.sensitivity, activeProfile)
        previewMapper = mapper.withSensitivity(activeProfile.sensitivity); previewTilt = BoardTilt()
        publish(snapshot.copy(status = "calibrating", message = "BoBo calibration active", tilt = BoardTilt(), calibration = calibrationStatus("started")))
    }
    fun selectBoardCalibrationPose(pose: BoardPose) {
        val capture = pendingCalibration ?: return
        if (capture.capturing) return
        capture.selectPose(pose)
        publish(snapshot.copy(calibration = calibrationStatus("selected")))
    }
    fun captureBoardCalibrationPose() {
        val capture = pendingCalibration ?: return
        if (!liveTilt() || capture.capturing) return
        capture.startCapture(nowMs())
        publish(snapshot.copy(calibration = calibrationStatus("capturing")))
    }
    fun cancelBoardCalibration() {
        if (pendingCalibration == null) return
        pendingCalibration = null; previewMapper = null; previewTilt = BoardTilt(); mapper.reset()
        lastPacket = -1; deadline = nowMs() + 5000
        publish(snapshot.copy(status = "waiting", tilt = BoardTilt(), fresh = false,
            message = "Calibration cancelled. Current profile kept.", calibration = BoardCalibrationStatus(event = "cancelled")))
    }
    /** Draft controls affect only the preview until an explicit save succeeds. */
    fun setBoardSensitivityPercent(control: BoardSensitivityControl, percent: Int) {
        val capture = pendingCalibration ?: return
        if (capture.capturing || !liveTilt()) return
        val settings = capture.sensitivity.withPercent(control, percent)
        if (settings == capture.sensitivity) return
        capture.changeSensitivity(settings)
        previewMapper = (capture.acceptedMapper ?: mapper).withSensitivity(settings); previewTilt = BoardTilt()
        publish(snapshot.copy(calibration = calibrationStatus("sensitivity_changed")))
    }
    /** Save controls using the current accepted poses, retaining unfinished captures.
     * The store compares current bytes, so a lost acknowledgement can be retried.
     */
    fun saveBoardSensitivity() {
        val capture = pendingCalibration ?: return
        if (capture.capturing || !liveTilt()) return
        val candidate = activeProfile.copy(sensitivity = capture.sensitivity)
        if (!candidate.hasSameValues(activeProfile)) {
            val address = boardAddress ?: return
            try { store?.saveBoardCalibration(address, candidate) }
            catch (error: Exception) {
                publish(snapshot.copy(calibration = calibrationStatus("sensitivity_failed",
                    "Could not confirm the sensitivity save. Active profile kept. Retry Save sensitivity. " + error.message))); return
            }
            activeProfile = candidate
            mapper = mapper.withSensitivity(candidate.sensitivity)
        }
        publish(snapshot.copy(calibrationSource = if (store == null) "Custom calibration (session)" else "Saved for this board",
            calibration = calibrationStatus("sensitivity_saved", "Sensitivity saved. Five-pose capture is optional.")))
    }
    fun saveBoardCalibration() {
        val capture = pendingCalibration ?: return
        val candidate = capture.acceptedProfile
        val fitted = capture.acceptedMapper
        if (candidate == null || fitted == null || !capture.canSaveCalibration || !liveTilt()) {
            publish(snapshot.copy(calibration = calibrationStatus("save_failed", "Capture five acceptable poses with live tilt before saving."))); return
        }
        saveCalibrationProfile(candidate, fitted, "saved", "BoBo calibration saved")
    }
    /** Save only the measured center and keep the existing directional poses and controls. */
    fun saveBoardCenter() {
        val capture = pendingCalibration ?: return
        if (!capture.canSaveCenter || !liveTilt()) return
        val settings = activeProfile.sensitivity
        val candidate = capture.acceptedProfile?.copy(sensitivity = settings) ?: return
        val fitted = capture.acceptedMapper?.withSensitivity(settings) ?: return
        saveCalibrationProfile(candidate, fitted, "center_saved", "BoBo center saved")
    }
    private fun saveCalibrationProfile(candidate: BoardCalibration, fitted: BoardTiltMapper, event: String, message: String) {
        val address = boardAddress ?: return
        try { store?.saveBoardCalibration(address, candidate) }
        catch (error: Exception) {
            publish(snapshot.copy(calibration = calibrationStatus("save_failed", "Could not confirm the BoBo calibration save. Active profile kept. Retry Save. " + error.message))); return
        }
        activeProfile = candidate; mapper = fitted; pendingCalibration = null; previewMapper = null; previewTilt = BoardTilt()
        lastPacket = -1; deadline = nowMs() + 5000
        publish(snapshot.copy(status = "waiting", message = message, tilt = BoardTilt(), fresh = false,
            calibrationSource = if (store == null) "Custom calibration (session)" else "Saved for this board",
            calibration = BoardCalibrationStatus(event = event, message = message)))
    }
    fun restoreImportedBoardCalibration() {
        val address = boardAddress ?: return
        if (!liveTilt() || pendingCalibration?.capturing == true) return
        try { store?.saveBoardCalibration(address, importedDefault) }
        catch (error: Exception) {
            publish(snapshot.copy(calibration = calibrationStatus("restore_failed", "Could not confirm the imported-profile restore. Active profile kept. Retry Restore. " + error.message))); return
        }
        if (pendingCalibration == null && activeProfile.hasSameValues(importedDefault)) {
            publish(snapshot.copy(calibrationSource = "Imported default",
                calibration = BoardCalibrationStatus(event = "restored", message = "Imported default is already active.")))
            return
        }
        activeProfile = importedDefault; fallbackProfile = importedDefault
        mapper = BoardTiltMapper.fromCalibration(importedDefault); pendingCalibration = null; previewMapper = null; previewTilt = BoardTilt()
        lastPacket = -1; deadline = nowMs() + 5000
        publish(snapshot.copy(status = "waiting", message = "Imported calibration restored", tilt = BoardTilt(), fresh = false,
            calibrationSource = "Imported default", calibration = BoardCalibrationStatus(event = "restored", message = "Imported default restored.")))
    }
    private fun fail(reason: String) {
        wanted = false
        if (snapshot.status != "releasing") release(true, reason)
    }
    private fun release(error: Boolean, message: String) {
        val token = ++generation
        pendingCalibration = null; previewMapper = null; previewTilt = BoardTilt(); boardAddress = null
        mapper.reset(); lastPacket = -1
        publish(snapshot.copy(status = "releasing", message = "Releasing BoBo", tilt = BoardTilt(), fresh = false, calibration = BoardCalibrationStatus(event = "cancelled")))
        try {
            radio.stopScanning()
            radio.releaseBoard { acknowledged ->
                if (token == generation && snapshot.status == "releasing") {
                    val detail = if (acknowledged) message else message + ". Local connection closed; board disconnect acknowledgement timed out."
                    publish(BoardSnapshot(if (error) "error" else "disconnected", detail, calibrationSource = snapshot.calibrationSource))
                    if (wanted) startScan()
                }
            }
        } catch (failure: Exception) {
            // The radio contract requires best-effort closure before throwing.
            publish(BoardSnapshot("error", "BoBo release failed: " + failure.message))
        }
    }
}
