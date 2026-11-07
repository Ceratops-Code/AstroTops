package io.github.ceratops_code.boboboard

import org.json.JSONArray
import org.json.JSONObject
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.*

/** Screen coordinates: right is positive X and down is positive Y. */
data class BoardTilt(val x: Float = 0f, val y: Float = 0f)
enum class BoardPose { CENTER, LEFT, RIGHT, UP, DOWN }

data class BoardSensitivity(
    val left: Double = 1.0, val right: Double = 1.0,
    val up: Double = 1.0, val down: Double = 1.0, val deadZone: Double = 0.08,
) {
    init {
        require(listOf(left, right, up, down).all { it.isFinite() && it in 0.5..2.0 })
        require(deadZone.isFinite() && deadZone in 0.0..0.30)
    }
    fun percent(control: BoardSensitivityControl): Int = ((when (control) {
        BoardSensitivityControl.LEFT -> left; BoardSensitivityControl.RIGHT -> right
        BoardSensitivityControl.UP -> up; BoardSensitivityControl.DOWN -> down
        BoardSensitivityControl.DEAD_ZONE -> deadZone
    }) * 100).roundToInt()
    fun withPercent(control: BoardSensitivityControl, percent: Int): BoardSensitivity {
        require(percent in control.minimumPercent..control.maximumPercent) { "Sensitivity is outside the supported range." }
        val value = percent / 100.0
        return when (control) {
            BoardSensitivityControl.LEFT -> copy(left = value); BoardSensitivityControl.RIGHT -> copy(right = value)
            BoardSensitivityControl.UP -> copy(up = value); BoardSensitivityControl.DOWN -> copy(down = value)
            BoardSensitivityControl.DEAD_ZONE -> copy(deadZone = value)
        }
    }
}

/** Hosts render these controls; the board module owns their names and bounds. */
enum class BoardSensitivityControl(val label: String, val minimumPercent: Int, val maximumPercent: Int) {
    LEFT("Left", 50, 200), RIGHT("Right", 50, 200), UP("Forward", 50, 200),
    DOWN("Backward", 50, 200), DEAD_ZONE("Center dead zone", 0, 30),
}

/** A portable profile contains sensor samples and controls, never a Bluetooth address.
 * Hosts may supply another profile; the bundled one was imported from WobblePad.
 */
data class BoardCalibration(
    val samples: Map<BoardPose, List<DoubleArray>>,
    val sensitivity: BoardSensitivity,
) {
    fun toJson(): String {
        val poses = JSONObject()
        BoardPose.entries.forEach { pose ->
            poses.put(pose.name, JSONArray().apply {
                samples.getValue(pose).forEach { row -> put(JSONArray(row.toList())) }
            })
        }
        return JSONObject().put("schema", "bobo-board-calibration.v1").put("samples", poses)
            .put("settings", JSONObject().put("left", sensitivity.left).put("right", sensitivity.right)
                .put("up", sensitivity.up).put("down", sensitivity.down).put("dead_zone", sensitivity.deadZone)).toString()
    }
    fun hasSameValues(other: BoardCalibration): Boolean = sensitivity == other.sensitivity &&
        BoardPose.entries.all { pose ->
            val first = samples[pose]; val second = other.samples[pose]
            first != null && second != null && first.size == second.size &&
                first.indices.all { first[it].contentEquals(second[it]) }
        }

    companion object {
        fun fromJson(text: String): BoardCalibration {
            val root = JSONObject(text)
            require(root.getString("schema") == "bobo-board-calibration.v1") { "Unsupported BoBo calibration schema." }
            val poses = root.getJSONObject("samples")
            val samples = BoardPose.entries.associateWith { pose ->
                val rows = poses.getJSONArray(pose.name)
                require(rows.length() in 10..500) { "Each calibration pose needs 10 to 500 samples." }
                List(rows.length()) { index ->
                    val row = rows.getJSONArray(index)
                    require(row.length() == 9) { "Calibration samples must have nine sensor values." }
                    DoubleArray(9) { row.getDouble(it) }
                }
            }
            val settings = root.getJSONObject("settings")
            val result = BoardCalibration(samples, BoardSensitivity(
                left = settings.getDouble("left"), right = settings.getDouble("right"),
                up = settings.getDouble("up"), down = settings.getDouble("down"),
                deadZone = settings.getDouble("dead_zone"),
            ))
            BoardTiltMapper.fromCalibration(result)
            return result
        }
    }
}

/** Pending poses never replace the active profile. A completed candidate retains
 * the mapper that passed the geometry/noise checks, so Save does not refit it.
 * Capture buffers are bounded and exist only in memory until an explicit Save.
 */
class BoardCalibrationCapture(sensitivity: BoardSensitivity, private val baseProfile: BoardCalibration? = null) {
    var sensitivity = sensitivity; private set
    var pose = BoardPose.CENTER; private set
    val captured: Set<BoardPose> get() = samples.keys.toSet()
    var message = "Place the board level, then capture Center."; private set
    var acceptedProfile: BoardCalibration? = null; private set
    var acceptedMapper: BoardTiltMapper? = null; private set
    private val samples = linkedMapOf<BoardPose, List<DoubleArray>>()
    val canSaveCenter get() = acceptedProfile != null && samples.size == 1 && BoardPose.CENTER in samples
    val canSaveCalibration get() = acceptedProfile != null && samples.size == BoardPose.entries.size
    private val current = mutableListOf<DoubleArray>()
    private var captureUntil: Long? = null
    val capturing get() = captureUntil != null
    internal fun reportActionFailure(reason: String) { message = reason }
    fun changeSensitivity(value: BoardSensitivity) {
        check(!capturing) { "Finish the current capture first." }
        sensitivity = value
        // Controls do not change accepted pose geometry or require another fit.
        acceptedProfile = acceptedProfile?.copy(sensitivity = value)
        acceptedMapper = acceptedMapper?.withSensitivity(value)
    }
    fun remainingMs(now: Long) = captureUntil?.let { max(0, it - now) } ?: 0L
    fun selectPose(value: BoardPose) {
        check(!capturing) { "Finish the current capture first." }
        pose = value
        message = "Hold the selected pose steady, then tap Capture."
    }
    fun startCapture(now: Long) {
        if (capturing) return
        acceptedProfile = null; acceptedMapper = null; current.clear()
        captureUntil = now + 3000
        message = "Hold still for three seconds."
    }
    fun acceptPacket(values: DoubleArray, now: Long) {
        val until = captureUntil ?: return
        if (now <= until && current.size < 500) current.add(values.copyOf())
    }
    fun finishCaptureIfDue(now: Long): Boolean {
        val until = captureUntil ?: return false
        if (now < until) return false
        captureUntil = null
        if (current.size < 10) {
            current.clear()
            message = "Too few live packets. Keep the board awake and capture this pose again."
            return true
        }
        samples[pose] = current.map { it.copyOf() }; current.clear()
        val missing = BoardPose.entries.firstOrNull { it !in samples }
        val centerBase = baseProfile?.takeIf { samples.size == 1 && BoardPose.CENTER in samples }
        if (missing != null && centerBase == null) {
            pose = missing
            message = "Pose captured. Move to the highlighted pose."
        } else {
            val poses = if (centerBase != null) centerBase.samples + samples else samples
            val candidate = BoardCalibration(poses.mapValues { (_, rows) -> rows.map { it.copyOf() } }, sensitivity)
            try {
                val fitted = BoardTiltMapper.fromCalibration(candidate)
                acceptedProfile = candidate; acceptedMapper = fitted
                if (centerBase != null) {
                    pose = BoardPose.LEFT
                    message = "Center captured. Save Center keeps your saved sensitivity and four direction poses. You can also continue a full calibration."
                } else {
                    message = "All five poses passed. Save, or select a pose to capture it again."
                }
            } catch (error: IllegalArgumentException) {
                message = (error.message ?: "The poses did not pass.") + " Select a pose to capture it again."
            }
        }
        return true
    }
}

/** Decodes only the observed 20-byte BoBo notification, including its frame markers. */
object BoardPacketParser {
    fun parse(packet: ByteArray): DoubleArray? {
        if (packet.size != 20 || packet[0] != 0x41.toByte() || packet[19] != 0x42.toByte()) return null
        val buffer = ByteBuffer.wrap(packet, 1, 18).order(ByteOrder.LITTLE_ENDIAN)
        return DoubleArray(9) { buffer.short.toDouble() }
    }
}

/** Derived from WobblePad's Apache-2.0 least-squares mapper. The time filter and
 * radial dead zone are shared by preview and gameplay; Y is converted once here.
 */
class BoardTiltMapper private constructor(
    private val center: DoubleArray, private val a: DoubleArray, private val b: DoubleArray,
    private val gains: DoubleArray, private val controls: BoardSensitivity,
) {
    private var filteredX = 0.0
    private var filteredY = 0.0
    private var lastNanos: Long? = null
    /** Reuse accepted geometry while starting a fresh, independent time filter. */
    fun withSensitivity(value: BoardSensitivity) = BoardTiltMapper(center, a, b, gains, value)
    fun reset() { filteredX = 0.0; filteredY = 0.0; lastNanos = null }
    fun project(values: DoubleArray): Pair<Double, Double> {
        require(values.size == 9 && values.all { it.isFinite() })
        val d = DoubleArray(9) { values[it] - center[it] }
        val aa = dot(a, a); val ab = dot(a, b); val bb = dot(b, b)
        val determinant = aa * bb - ab * ab
        return (dot(a, d) * bb - dot(b, d) * ab) / determinant to
            (dot(b, d) * aa - dot(a, d) * ab) / determinant
    }
    fun update(values: DoubleArray, nowNanos: Long): BoardTilt {
        val (px, py) = project(values)
        val x = px / gains[if (px >= 0) 0 else 1]
        val y = py / gains[if (py >= 0) 2 else 3]
        // The dead zone is a fraction of calibrated tilt, independent of gain.
        // Entering it also clears filter history so old tilt cannot keep steering.
        if (hypot(x, y) <= controls.deadZone) {
            reset()
            return BoardTilt()
        }
        val previous = lastNanos
        val alpha = if (previous == null) 1.0 else 1 - exp(-max(0L, nowNanos - previous) / 60_000_000.0)
        filteredX += alpha * (x - filteredX); filteredY += alpha * (y - filteredY)
        lastNanos = nowNanos
        val radius = hypot(filteredX, filteredY)
        if (radius <= controls.deadZone) return BoardTilt()
        val scale = (radius - controls.deadZone) / (1.0 - controls.deadZone) / radius
        val outputX = filteredX * scale * if (filteredX >= 0) controls.right else controls.left
        val outputY = filteredY * scale * if (filteredY >= 0) controls.up else controls.down
        val limit = max(1.0, hypot(outputX, outputY))
        return BoardTilt((outputX / limit).toFloat(), (-outputY / limit).toFloat())
    }
    companion object {
        private fun dot(a: DoubleArray, b: DoubleArray) = a.indices.sumOf { a[it] * b[it] }
        fun fromCalibration(profile: BoardCalibration): BoardTiltMapper {
            val samples = profile.samples
            require(BoardPose.entries.all { samples[it]?.size in 10..500 }) { "Capture all five BoBo poses." }
            require(samples.values.flatten().all { it.size == 9 && it.all { n -> n.isFinite() && n in -32768.0..32767.0 } }) {
                "Calibration contains invalid sensor values."
            }
            val means = samples.mapValues { (_, rows) -> DoubleArray(9) { i -> rows.sumOf { it[i] } / rows.size } }
            val center = means.getValue(BoardPose.CENTER)
            val a = DoubleArray(9) { (means.getValue(BoardPose.RIGHT)[it] - means.getValue(BoardPose.LEFT)[it]) / 2 }
            val b = DoubleArray(9) { (means.getValue(BoardPose.UP)[it] - means.getValue(BoardPose.DOWN)[it]) / 2 }
            val aa = dot(a, a); val bb = dot(b, b); val ab = dot(a, b)
            val noise = samples.maxOf { (pose, rows) ->
                sqrt(rows.sumOf { row -> row.indices.sumOf { i -> (row[i] - means.getValue(pose)[i]).pow(2) } } / rows.size)
            }
            require(min(aa, bb) > max(1.0, 4 * noise).pow(2)) { "Calibration poses were unsteady or too small." }
            require(aa * bb - ab * ab > 0.01 * aa * bb) { "Calibration tilt axes are too similar." }
            val first = BoardTiltMapper(center, a, b, doubleArrayOf(1.0, 1.0, 1.0, 1.0), profile.sensitivity)
            val gains = doubleArrayOf(first.project(means.getValue(BoardPose.RIGHT)).first,
                -first.project(means.getValue(BoardPose.LEFT)).first,
                first.project(means.getValue(BoardPose.UP)).second,
                -first.project(means.getValue(BoardPose.DOWN)).second)
            require(gains.all { it > 0.2 }) { "Center must lie between the opposite tilts." }
            return BoardTiltMapper(center, a, b, gains, profile.sensitivity)
        }
    }
}
