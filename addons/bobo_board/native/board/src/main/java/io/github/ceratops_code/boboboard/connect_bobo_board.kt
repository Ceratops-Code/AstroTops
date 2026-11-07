package io.github.ceratops_code.boboboard

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.AtomicFile
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.security.MessageDigest
import java.util.Locale

/** Public Android entry point, independent of any game engine. Call on the main
 * thread. Close when the host leaves the foreground; this is not a background bridge.
 * The client owns per-board calibration files in its host's private files directory.
 * All clients use the main thread in one application process; no operational logs.
 */
class BoboBoardClient(context: Context, changed: (BoardSnapshot) -> Unit) {
    private val handler = Handler(Looper.getMainLooper())
    private var closed = false
    private val session = BoboBoardSession(AndroidBoardRadio(context.applicationContext),
        loadBundledCalibration(context), SystemClock::elapsedRealtime,
        changed = { if (!closed) changed(it) }, store = AndroidBoardCalibrationStore(context.applicationContext))
    val snapshot get() = session.snapshot
    private val tick = object : Runnable {
        override fun run() {
            if (closed) return
            session.checkTiltFreshness()
            handler.postDelayed(this, 100)
        }
    }
    init { handler.post(tick) }
    fun connectToBoBoBoard() { check(!closed) { "BoBo client is closed." }; session.connectToBoBoBoard() }
    fun disconnectFromBoBoBoard() { session.disconnectFromBoBoBoard() }
    fun setCalibrationJson(text: String) { session.replaceCalibration(BoardCalibration.fromJson(text)) }
    fun beginBoardCalibration() { session.beginBoardCalibration() }
    fun selectBoardCalibrationPose(pose: String) { session.selectBoardCalibrationPose(BoardPose.valueOf(pose)) }
    fun captureBoardCalibrationPose() { session.captureBoardCalibrationPose() }
    fun saveBoardCenter() { session.saveBoardCenter() }
    fun cancelBoardCalibration() { session.cancelBoardCalibration() }
    fun saveBoardCalibration() { session.saveBoardCalibration() }
    fun setBoardSensitivityPercent(control: String, percent: Int) { session.setBoardSensitivityPercent(BoardSensitivityControl.valueOf(control), percent) }
    fun saveBoardSensitivity() { session.saveBoardSensitivity() }
    fun restoreImportedBoardCalibration() { session.restoreImportedBoardCalibration() }
    fun close() {
        if (closed) return
        session.disconnectFromBoBoBoard()
        closed = true
        handler.removeCallbacks(tick)
    }
    companion object {
        fun loadBundledCalibration(context: Context): BoardCalibration =
            context.assets.open("bobo_board/default_calibration.json").bufferedReader().use { BoardCalibration.fromJson(it.readText()) }
    }
}

/** One current JSON per board, named by an address digest rather than the address.
 * AtomicFile owns .new/.bak recovery. Startup and each operation discard only
 * module-owned orphan staging files while a process-wide lock excludes live writes.
 * This store is for the client's documented single application process.
 */
private class AndroidBoardCalibrationStore(context: Context) : BoardCalibrationStore {
    private val directory = File(context.filesDir, "bobo_board/calibrations")
    init { synchronized(storageLock) { cleanOrphanFiles() } }
    private fun profileFile(address: String): File {
        val digest = MessageDigest.getInstance("SHA-256").digest(address.uppercase(Locale.ROOT).toByteArray(Charsets.UTF_8))
        val name = digest.joinToString("") { (it.toInt() and 255).toString(16).padStart(2, '0') }
        return File(directory, name + ".json")
    }
    private fun cleanOrphanFiles() {
        val files = directory.listFiles().orEmpty().filter { ownedName.matches(it.name) && (it.name.endsWith(".new") || it.name.endsWith(".bak")) }
        files.map { it.name.removeSuffix(".new").removeSuffix(".bak") }.distinct().forEach { name ->
            val base = File(directory, name)
            if (base.exists() || File(base.path + ".bak").exists()) AtomicFile(base).openRead().close()
            val staging = File(base.path + ".new")
            if (staging.exists() && !staging.delete()) throw IOException("Could not remove incomplete BoBo calibration " + staging.name)
        }
    }
    override fun readBoardCalibration(address: String): BoardCalibration? = synchronized(storageLock) {
        cleanOrphanFiles()
        val file = profileFile(address)
        if (!file.exists()) return@synchronized null
        AtomicFile(file).openRead().use { stream ->
            require(stream.channel.size() <= 1024 * 1024) { "Saved BoBo calibration exceeds its size limit." }
            BoardCalibration.fromJson(stream.readBytes().toString(Charsets.UTF_8))
        }
    }
    override fun saveBoardCalibration(address: String, profile: BoardCalibration) = synchronized(storageLock) {
        if (runCatching { readBoardCalibration(address)?.hasSameValues(profile) == true }.getOrDefault(false)) return@synchronized
        check(directory.isDirectory || directory.mkdirs()) { "Could not create private BoBo calibration storage." }
        val file = AtomicFile(profileFile(address))
        val bytes = profile.toJson().toByteArray(Charsets.UTF_8)
        var stream: FileOutputStream? = null
        try {
            stream = file.startWrite()
            stream.write(bytes)
            file.finishWrite(stream)
            stream = null
            check(file.readFully().contentEquals(bytes)) { "The BoBo calibration write did not complete." }
            cleanOrphanFiles()
        } catch (error: Exception) {
            if (stream != null) file.failWrite(stream)
            throw IOException("Saving BoBo calibration failed for " + file.baseFile.name + ": " + error.message, error)
        }
    }
    companion object {
        private val storageLock = Any()
        private val ownedName = Regex("[0-9a-f]{64}\\.json(?:\\.new|\\.bak)?")
    }
}
