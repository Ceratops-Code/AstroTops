package io.github.ceratops_code.boboboard

import org.junit.Assert.*
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.hypot

/** Functional tests exercise radio effects through a controllable port. They never
 * inspect executable source or replace the physical-board qualification.
 */
class BoardBehaviorTest {
    private class Radio : BoardRadio {
        var scans = 0; var connects = 0; var releases = 0
        var scanning = false; var open = false
        var found: ((String) -> Unit)? = null
        var events: BoardRadioEvents? = null
        var released: ((Boolean) -> Unit)? = null
        var breakScan = 0
        var breakConnect = 0
        override fun scanForBoard(found: (String) -> Unit, failed: (String) -> Unit) {
            scans++
            if (breakScan == 1) throw IllegalStateException("before scan")
            scanning = true; this.found = found
            if (breakScan == 2) throw IllegalStateException("after scan")
        }
        override fun stopScanning() { scanning = false }
        override fun connectToBoard(address: String, events: BoardRadioEvents) {
            connects++
            if (breakConnect == 1) throw IllegalStateException("before connect")
            open = true; this.events = events
            if (breakConnect == 2) throw IllegalStateException("after connect")
        }
        override fun releaseBoard(released: (Boolean) -> Unit) { releases++; this.released = released }
        fun finishRelease(acknowledged: Boolean = true) { open = false; released?.invoke(acknowledged) }
    }
    private class Harness(val radio: Radio = Radio(), store: BoardCalibrationStore? = null, profile: BoardCalibration = calibration()) {
        var clock = 1L
        val history = mutableListOf<BoardSnapshot>()
        val session = BoboBoardSession(radio, profile, { clock }, history::add, store)
        fun ready(address: String = "test-board") {
            session.connectToBoBoBoard()
            radio.found!!.invoke(address)
            radio.events!!.ready()
        }
        fun tilt(x: Short = 100, y: Short = 0) { radio.events!!.packet(packet(x, y)) }
        fun capturePose(pose: BoardPose, x: Short, y: Short, packets: Int = 15) {
            session.selectBoardCalibrationPose(pose)
            session.captureBoardCalibrationPose()
            repeat(packets) {
                clock += 3000 / packets
                tilt(x, y)
                session.checkTiltFreshness()
            }
        }
        fun captureAll() {
            session.beginBoardCalibration()
            capturePose(BoardPose.CENTER, 0, 0)
            capturePose(BoardPose.LEFT, -200, 0)
            capturePose(BoardPose.RIGHT, 200, 0)
            capturePose(BoardPose.UP, 0, 200)
            capturePose(BoardPose.DOWN, 0, -200)
        }
    }
    @Test fun packetParserAcceptsSignedFieldsAndRejectsBadFrames() {
        val decoded = BoardPacketParser.parse(packet(-123, 456))!!
        assertEquals(-123.0, decoded[0], 0.0); assertEquals(456.0, decoded[1], 0.0)
        assertNull(BoardPacketParser.parse(ByteArray(19)))
        assertNull(BoardPacketParser.parse(packet(0, 0).apply { this[19] = 0 }))
    }
    @Test fun importedDefaultHasEveryPoseAndPreservesSavedSensitivity() {
        val text = javaClass.getResourceAsStream("/bobo_board/default_calibration.json")!!.bufferedReader().use { it.readText() }
        val profile = BoardCalibration.fromJson(text)
        assertEquals(BoardPose.entries.toSet(), profile.samples.keys)
        assertEquals(84, profile.samples.values.sumOf { it.size })
        assertEquals(1.43, profile.sensitivity.left, 0.0)
        assertEquals(1.43, profile.sensitivity.right, 0.0)
        assertEquals(1.43, profile.sensitivity.up, 0.0)
        assertEquals(1.43, profile.sensitivity.down, 0.0)
        assertEquals(0.11, profile.sensitivity.deadZone, 0.0)
        for (pose in BoardPose.entries) {
            val mapper = BoardTiltMapper.fromCalibration(profile)
            val rows = profile.samples.getValue(pose)
            val mean = DoubleArray(9) { i -> rows.sumOf { it[i] } / rows.size }
            val tilt = mapper.update(mean, 1)
            when (pose) {
                BoardPose.CENTER -> assertEquals(BoardTilt(), tilt)
                BoardPose.LEFT -> assertTrue(tilt.x < -0.9)
                BoardPose.RIGHT -> assertTrue(tilt.x > 0.9)
                BoardPose.UP -> assertTrue(tilt.y < -0.9)
                BoardPose.DOWN -> assertTrue(tilt.y > 0.9)
            }
        }
        assertFalse(text.contains("\"device\""))
        assertFalse(text.contains("calibration:"))
    }
    @Test fun mapperPreservesDeadZoneFilterAndScreenDirection() {
        val mapper = BoardTiltMapper.fromCalibration(calibration())
        assertEquals(BoardTilt(), mapper.update(vector(5.0, 0.0), 0))
        mapper.reset()
        assertEquals(-1f, mapper.update(vector(0.0, 100.0), 0).y, 0.0001f)
        val held = mapper.update(vector(0.0, -100.0), 0)
        assertEquals(-1f, held.y, 0.0001f)
        assertTrue(mapper.update(vector(0.0, -100.0), 10_000_000_000).y > 0.99f)
        mapper.reset()
        val diagonal = mapper.update(vector(100.0, 100.0), 0)
        assertEquals(1.0, hypot(diagonal.x.toDouble(), diagonal.y.toDouble()), 0.0001)
    }
    @Test fun invalidCalibrationCannotReplaceAnAcceptedProfile() {
        val bad = calibration().copy(samples = calibration().samples - BoardPose.UP)
        assertThrows(IllegalArgumentException::class.java) { BoardTiltMapper.fromCalibration(bad) }
        assertThrows(IllegalArgumentException::class.java) { BoardSensitivity(deadZone = Double.NaN) }
        val h = Harness(); h.ready(); h.tilt()
        assertThrows(IllegalArgumentException::class.java) { h.session.replaceCalibration(bad) }
        h.tilt()
        assertTrue(h.session.snapshot.fresh)
    }
    @Test fun deadZoneBoundaryStaysFixedAtEveryDirectionalSensitivity() {
        for (gain in listOf(0.5, 1.0, 1.43, 2.0)) {
            val settings = BoardSensitivity(gain, gain, gain, gain, 0.11)
            val mapper = BoardTiltMapper.fromCalibration(calibration().copy(sensitivity = settings))
            for ((x, y) in listOf(10.0 to 0.0, -10.0 to 0.0, 0.0 to 10.0, 0.0 to -10.0,
                7.0 to 7.0, -7.0 to -7.0, 11.0 to 0.0)) {
                repeat(2) { assertEquals(BoardTilt(), mapper.update(vector(x, y), it.toLong())) }
            }
            for ((x, y) in listOf(12.0 to 0.0, -12.0 to 0.0, 0.0 to 12.0, 0.0 to -12.0)) {
                mapper.reset()
                val actual = mapper.update(vector(x, y), 0)
                assertTrue(hypot(actual.x.toDouble(), actual.y.toDouble()) > 0)
                assertTrue(actual.x * x >= 0 && actual.y * y <= 0)
            }
            mapper.reset()
            assertEquals(minOf(1.0, gain).toFloat(), mapper.update(vector(100.0, 0.0), 0).x, 0.0001f)
        }
    }
    @Test fun enteringDeadZoneImmediatelyClearsOldFilteredTilt() {
        val mapper = BoardTiltMapper.fromCalibration(calibration().copy(sensitivity = BoardSensitivity(deadZone = 0.11)))
        assertEquals(1f, mapper.update(vector(100.0, 0.0), 0).x, 0.0001f)
        assertEquals(BoardTilt(), mapper.update(vector(10.0, 0.0), 1_000_000))
        assertEquals(BoardTilt(), mapper.update(vector(0.0, 0.0), 2_000_000))
        val next = mapper.update(vector(-12.0, 0.0), 3_000_000)
        assertTrue(next.x < 0 && next.x > -0.02f)
    }
    @Test fun importedCenterSamplesAndSmallTiltsStayStillWithoutRecapturing() {
        val profile = BoardCalibration.fromJson(javaClass.getResourceAsStream("/bobo_board/default_calibration.json")!!.bufferedReader().use { it.readText() })
        val mapper = BoardTiltMapper.fromCalibration(profile)
        val centerRows = profile.samples.getValue(BoardPose.CENTER)
        val center = DoubleArray(9) { i -> centerRows.sumOf { it[i] } / centerRows.size }
        for (pose in BoardPose.entries.filter { it != BoardPose.CENTER }) {
            val rows = profile.samples.getValue(pose)
            val full = DoubleArray(9) { i -> rows.sumOf { it[i] } / rows.size }
            val small = DoubleArray(9) { i -> center[i] + 0.10 * (full[i] - center[i]) }
            repeat(2) {
                assertTrue(mapper.update(full, 0) != BoardTilt())
                assertEquals(BoardTilt(), mapper.update(small, 1_000_000))
                centerRows.forEachIndexed { index, values -> assertEquals(BoardTilt(), mapper.update(values, (index + 2) * 1_000_000L)) }
            }
        }
    }
    @Test fun connectIsRepeatedSafelyBeforeAndAfterEveryConnectionEffect() {
        val h = Harness()
        repeat(3) { h.session.connectToBoBoBoard() }
        assertEquals(1, h.radio.scans)
        h.radio.found!!.invoke("test-board")
        repeat(3) { h.session.connectToBoBoBoard() }
        assertEquals(1, h.radio.connects)
        assertFalse(h.session.snapshot.fresh)
        h.radio.events!!.ready()
        assertEquals("waiting", h.session.snapshot.status)
        assertFalse(h.session.snapshot.fresh)
        h.tilt()
        repeat(3) { h.session.connectToBoBoBoard() }
        assertEquals("ready", h.session.snapshot.status)
        assertEquals(1, h.radio.connects)
    }
    @Test fun disconnectBeforeDiscoveryPreventsLateConnectionAndReacquisition() {
        val h = Harness()
        h.session.connectToBoBoBoard()
        val late = h.radio.found!!
        h.session.disconnectFromBoBoBoard()
        repeat(3) { h.session.disconnectFromBoBoBoard() }
        late("test-board")
        assertFalse(h.radio.scanning)
        assertEquals(0, h.radio.connects)
        assertEquals(1, h.radio.releases)
        h.radio.finishRelease()
        repeat(3) { h.session.disconnectFromBoBoBoard(); h.session.checkTiltFreshness() }
        assertEquals("disconnected", h.session.snapshot.status)
        assertEquals(1, h.radio.scans)
    }
    @Test fun disconnectAroundReadyAndPacketEffectsAlwaysClearsInput() {
        for (boundary in 0..2) {
            val h = Harness()
            h.session.connectToBoBoBoard(); h.radio.found!!.invoke("test-board")
            val late = h.radio.events!!
            if (boundary >= 1) late.ready()
            if (boundary >= 2) h.tilt()
            h.session.disconnectFromBoBoBoard()
            assertEquals(BoardTilt(), h.session.snapshot.tilt)
            assertFalse(h.session.snapshot.fresh)
            assertEquals("releasing", h.session.snapshot.status)
            late.ready(); late.packet(packet(100, 0))
            assertFalse(h.session.snapshot.fresh)
            h.radio.finishRelease()
            h.radio.finishRelease()
            assertEquals("disconnected", h.session.snapshot.status)
            assertFalse(h.radio.open)
            assertEquals(1, h.radio.releases)
        }
    }
    @Test fun connectDuringReleaseWaitsForClosureAndUsesCurrentIntent() {
        val h = Harness(); h.ready(); h.tilt()
        h.session.disconnectFromBoBoBoard()
        h.session.connectToBoBoBoard()
        assertEquals(1, h.radio.scans)
        h.radio.finishRelease()
        assertEquals(2, h.radio.scans)
        assertEquals("scanning", h.session.snapshot.status)
        h.session.disconnectFromBoBoBoard()
        h.session.connectToBoBoBoard()
        h.session.disconnectFromBoBoBoard()
        h.radio.finishRelease()
        assertEquals("disconnected", h.session.snapshot.status)
        assertEquals(2, h.radio.scans)
    }
    @Test fun staleAndMalformedPacketsNeverKeepTheShipMoving() {
        val h = Harness(); h.ready(); h.tilt()
        h.clock += 900
        h.radio.events!!.packet(ByteArray(20))
        h.clock += 101
        h.session.checkTiltFreshness()
        assertFalse(h.session.snapshot.fresh)
        assertEquals(BoardTilt(), h.session.snapshot.tilt)
        h.radio.finishRelease()
        assertEquals("error", h.session.snapshot.status)
        h.session.connectToBoBoBoard()
        assertEquals("scanning", h.session.snapshot.status)
    }
    @Test fun scanAndConnectInterruptionsCloseEffectsBeforeAFreshConnect() {
        for (kind in 0..1) for (boundary in 1..2) {
            val radio = Radio()
            if (kind == 0) radio.breakScan = boundary else radio.breakConnect = boundary
            val h = Harness(radio)
            h.session.connectToBoBoBoard()
            if (kind == 1) radio.found!!.invoke("test-board")
            assertEquals("releasing", h.session.snapshot.status)
            radio.finishRelease()
            assertFalse(radio.open); assertFalse(radio.scanning)
            radio.breakScan = 0; radio.breakConnect = 0
            h.ready(); h.tilt()
            assertTrue(h.session.snapshot.fresh)
        }
    }
    @Test fun releaseTimeoutIsReportedWithoutLeavingOwnedResourcesOpen() {
        val h = Harness(); h.ready()
        h.session.disconnectFromBoBoBoard()
        h.radio.finishRelease(false)
        assertEquals("disconnected", h.session.snapshot.status)
        assertTrue(h.session.snapshot.message.contains("acknowledgement timed out"))
        assertFalse(h.radio.open)
    }
    @Test fun scanConnectAndFirstTiltHaveBoundedFailureDeadlines() {
        for (phase in 0..2) {
            val h = Harness()
            h.session.connectToBoBoBoard()
            if (phase > 0) h.radio.found!!.invoke("test-board")
            if (phase > 1) h.radio.events!!.ready()
            h.clock += 20000
            h.session.checkTiltFreshness()
            assertEquals("releasing", h.session.snapshot.status)
            assertFalse(h.session.snapshot.fresh)
            h.radio.finishRelease()
            assertEquals("error", h.session.snapshot.status)
        }
    }
    private class Profiles : BoardCalibrationStore {
        val values = mutableMapOf<String, BoardCalibration>()
        var writes = 0
        var interruptBefore = false
        var interruptAfter = false
        override fun readBoardCalibration(address: String) = values[address]
        override fun saveBoardCalibration(address: String, profile: BoardCalibration) {
            if (values[address]?.hasSameValues(profile) == true) return
            if (interruptBefore) throw IllegalStateException("interrupted before profile write")
            values[address] = profile
            writes++
            if (interruptAfter) throw IllegalStateException("interrupted after profile write")
        }
    }
    @Test fun calibrationCaptureKeepsTheCurrentProfileUntilAnExplicitAcceptedSave() {
        val profiles = Profiles()
        val h = Harness(store = profiles); h.ready(); h.tilt()
        h.session.beginBoardCalibration()
        h.session.beginBoardCalibration()
        assertEquals("calibrating", h.session.snapshot.status)
        assertEquals(BoardTilt(), h.session.snapshot.tilt)
        h.capturePose(BoardPose.CENTER, 0, 0)
        h.session.saveBoardCalibration()
        assertEquals(0, profiles.writes)
        assertFalse(h.session.snapshot.calibration.canSave)
        h.session.cancelBoardCalibration()
        h.session.cancelBoardCalibration()
        h.tilt()
        assertEquals(1f, h.session.snapshot.tilt.x, 0.0001f)
        assertFalse(h.session.snapshot.calibration.active)
    }
    @Test fun allFivePosesSaveForOnlyTheirBoardAndLoadInAFreshClient() {
        val profiles = Profiles()
        val h = Harness(store = profiles); h.ready(); h.tilt()
        h.captureAll()
        assertTrue(h.session.snapshot.calibration.canSave)
        assertEquals(BoardPose.entries.map { it.name }.toSet(), h.session.snapshot.calibration.captured.toSet())
        h.session.saveBoardCalibration()
        h.session.saveBoardCalibration()
        assertEquals(1, profiles.writes)
        assertEquals("Saved for this board", h.session.snapshot.calibrationSource)
        h.tilt()
        assertEquals(((0.5 - 0.08) / 0.92).toFloat(), h.session.snapshot.tilt.x, 0.0001f)
        val stored = profiles.values.getValue("test-board")
        assertTrue(BoardCalibration.fromJson(stored.toJson()).hasSameValues(stored))
        val fresh = Harness(store = profiles); fresh.ready(); fresh.tilt()
        assertEquals(h.session.snapshot.tilt, fresh.session.snapshot.tilt)
        val other = Harness(store = profiles); other.ready("other-board"); other.tilt()
        assertEquals(1f, other.session.snapshot.tilt.x, 0.0001f)
        assertEquals(1, profiles.writes)
    }
    @Test fun cancellingOrDisconnectingAtEveryCaptureBoundaryKeepsTheSavedProfile() {
        for (disconnect in listOf(false, true)) for (boundary in 0..3) {
            val profiles = Profiles().apply { values["test-board"] = calibration() }
            val h = Harness(store = profiles); h.ready(); h.tilt()
            h.session.beginBoardCalibration()
            if (boundary >= 1) h.session.captureBoardCalibrationPose()
            if (boundary >= 2) { h.clock += 200; h.tilt(0, 0) }
            if (boundary >= 3) {
                repeat(14) { h.clock += 200; h.tilt(0, 0); h.session.checkTiltFreshness() }
            }
            if (disconnect) {
                h.session.disconnectFromBoBoBoard()
                h.radio.finishRelease()
                h.radio.events!!.packet(packet(200, 0))
            } else h.session.cancelBoardCalibration()
            assertFalse(h.session.snapshot.calibration.active)
            assertEquals(0, profiles.writes)
            assertTrue(profiles.values.getValue("test-board").hasSameValues(calibration()))
        }
    }
    @Test fun insufficientAndUnsteadyPosesCannotReplaceTheCurrentCalibration() {
        val profiles = Profiles()
        val h = Harness(store = profiles); h.ready(); h.tilt()
        h.session.beginBoardCalibration()
        h.capturePose(BoardPose.CENTER, 0, 0, packets = 5)
        assertTrue(h.session.snapshot.calibration.captured.isEmpty())
        assertTrue(h.session.snapshot.calibration.message.contains("Too few"))
        h.session.selectBoardCalibrationPose(BoardPose.CENTER)
        h.session.captureBoardCalibrationPose()
        repeat(15) { i ->
            h.clock += 200; h.tilt(if (i % 2 == 0) 200 else -200, 0); h.session.checkTiltFreshness()
        }
        h.capturePose(BoardPose.LEFT, -200, 0)
        h.capturePose(BoardPose.RIGHT, 200, 0)
        h.capturePose(BoardPose.UP, 0, 200)
        h.capturePose(BoardPose.DOWN, 0, -200)
        assertFalse(h.session.snapshot.calibration.canSave)
        h.session.saveBoardCalibration()
        assertEquals(0, profiles.writes)
        h.capturePose(BoardPose.CENTER, 0, 0)
        assertTrue(h.session.snapshot.calibration.canSave)
        h.session.saveBoardCalibration()
        assertEquals(1, profiles.writes)
    }
    @Test fun saveInterruptionsBeforeAndAfterTheEffectConvergeOnCurrentStorage() {
        for (after in listOf(false, true)) {
            val profiles = Profiles()
            val h = Harness(store = profiles); h.ready(); h.tilt(); h.captureAll()
            profiles.interruptBefore = !after; profiles.interruptAfter = after
            h.session.saveBoardCalibration()
            assertTrue(h.session.snapshot.calibration.active)
            assertEquals("Imported default", h.session.snapshot.calibrationSource)
            h.tilt()
            assertTrue(h.session.snapshot.calibration.message.contains("interrupted"))
            assertTrue(h.session.snapshot.calibration.message.contains("Could not confirm"))
            profiles.interruptBefore = false; profiles.interruptAfter = false
            h.session.saveBoardCalibration()
            assertEquals(1, profiles.writes)
            assertFalse(h.session.snapshot.calibration.active)
            val fresh = Harness(store = profiles); fresh.ready(); fresh.tilt()
            assertEquals(((0.5 - 0.08) / 0.92).toFloat(), fresh.session.snapshot.tilt.x, 0.0001f)
        }
    }
    @Test fun restoreDefaultIsScopedRepeatableAndSafeAcrossWriteInterruptions() {
        for (after in listOf(false, true)) {
            val profiles = Profiles()
            val h = Harness(store = profiles); h.ready(); h.tilt(); h.captureAll()
            h.session.saveBoardCalibration(); h.tilt()
            val custom = profiles.values.getValue("test-board")
            profiles.values["other-board"] = custom
            profiles.interruptBefore = !after; profiles.interruptAfter = after
            h.session.restoreImportedBoardCalibration()
            h.tilt()
            assertTrue(h.session.snapshot.calibration.message.contains("Active profile kept"))
            assertEquals(((0.5 - 0.08) / 0.92).toFloat(), h.session.snapshot.tilt.x, 0.0001f)
            profiles.interruptBefore = false; profiles.interruptAfter = false
            h.session.restoreImportedBoardCalibration(); h.tilt()
            h.session.restoreImportedBoardCalibration()
            assertEquals(2, profiles.writes)
            assertEquals(1f, h.session.snapshot.tilt.x, 0.0001f)
            assertEquals("Imported default", h.session.snapshot.calibrationSource)
            assertTrue(profiles.values.getValue("other-board").hasSameValues(custom))
        }
    }
    @Test fun lostTiltDuringCaptureDiscardsTheDraftAndNeverSavesIt() {
        val profiles = Profiles()
        val h = Harness(store = profiles); h.ready(); h.tilt()
        h.session.beginBoardCalibration(); h.session.captureBoardCalibrationPose()
        h.clock += 200; h.tilt(0, 0)
        h.clock += 1001; h.session.checkTiltFreshness()
        assertFalse(h.session.snapshot.calibration.active)
        assertEquals(BoardTilt(), h.session.snapshot.tilt)
        assertEquals(0, profiles.writes)
        h.radio.finishRelease()
        h.ready(); h.tilt()
        assertEquals(1f, h.session.snapshot.tilt.x, 0.0001f)
    }
    @Test fun repeatedCaptureCommandsDoNotRestartOrChangeTheLivePoseWindow() {
        val h = Harness(); h.ready(); h.tilt(); h.session.beginBoardCalibration()
        h.session.captureBoardCalibrationPose()
        h.clock += 200; h.tilt(0, 0)
        h.session.captureBoardCalibrationPose()
        h.session.selectBoardCalibrationPose(BoardPose.RIGHT)
        repeat(14) { h.clock += 200; h.tilt(0, 0); h.session.checkTiltFreshness() }
        assertEquals(listOf("CENTER"), h.session.snapshot.calibration.captured)
        assertFalse(h.session.snapshot.calibration.capturing)
        assertEquals("LEFT", h.session.snapshot.calibration.pose)
    }

    @Test fun anInvalidSavedProfileFallsBackAndRestoreRepairsItsStoredOverride() {
        val profiles = Profiles()
        profiles.values["test-board"] = calibration().copy(samples = calibration().samples - BoardPose.UP)
        val h = Harness(store = profiles); h.ready(); h.tilt()
        assertEquals(1f, h.session.snapshot.tilt.x, 0.0001f)
        assertTrue(h.session.snapshot.calibrationSource.contains("unavailable"))
        assertEquals(0, profiles.writes)
        h.session.restoreImportedBoardCalibration(); h.tilt()
        assertTrue(profiles.values.getValue("test-board").hasSameValues(calibration()))
        assertEquals(1, profiles.writes)
        h.session.restoreImportedBoardCalibration()
        assertEquals(1, profiles.writes)
    }

    @Test fun sensitivityControlsHaveWobblePadBoundsAndAffectOnlyTheirDirection() {
        val base = BoardTiltMapper.fromCalibration(calibration())
        for (control in BoardSensitivityControl.entries) {
            val settings = BoardSensitivity().withPercent(control, control.maximumPercent)
            assertEquals(control.maximumPercent, settings.percent(control))
            assertThrows(IllegalArgumentException::class.java) { settings.withPercent(control, control.minimumPercent - 1) }
            assertThrows(IllegalArgumentException::class.java) { settings.withPercent(control, control.maximumPercent + 1) }
        }
        val settings = BoardSensitivity(left = 0.5, right = 2.0, up = 0.75, down = 1.5, deadZone = 0.0)
        for ((values, expected) in listOf(vector(-40.0, 0.0) to BoardTilt(-0.2f, 0f),
            vector(40.0, 0.0) to BoardTilt(0.8f, 0f), vector(0.0, 40.0) to BoardTilt(0f, -0.3f),
            vector(0.0, -40.0) to BoardTilt(0f, 0.6f))) {
            val actual = base.withSensitivity(settings).update(values, 0)
            assertEquals(expected.x, actual.x, 0.0001f)
            assertEquals(expected.y, actual.y, 0.0001f)
        }
        assertEquals(BoardTilt(), base.withSensitivity(settings.copy(deadZone = 0.30)).update(vector(10.0, 0.0), 0))
    }
    @Test fun sensitivityPreviewNeverSteersAndCancellationOrDisconnectDiscardsUnsavedChanges() {
        for (disconnect in listOf(false, true)) for (changed in listOf(false, true)) {
            val profiles = Profiles()
            val h = Harness(store = profiles); h.ready(); h.tilt(); h.session.beginBoardCalibration()
            if (changed) repeat(2) { h.session.setBoardSensitivityPercent(BoardSensitivityControl.RIGHT, 50) }
            h.tilt(50)
            assertEquals(BoardTilt(), h.session.snapshot.tilt)
            val expected = (0.5 - 0.08) / 0.92 * if (changed) 0.5 else 1.0
            assertEquals(expected.toFloat(), h.session.snapshot.calibration.previewTilt.x, 0.0001f)
            if (disconnect) {
                h.session.disconnectFromBoBoBoard(); h.radio.finishRelease(); h.ready()
            } else h.session.cancelBoardCalibration()
            h.tilt()
            assertEquals(1f, h.session.snapshot.tilt.x, 0.0001f)
            assertEquals(0, profiles.writes)
        }
    }
    @Test fun sensitivitySaveSurvivesBothWriteBoundariesAndRepeatedCallsKeepCapturedPoses() {
        for (after in listOf(false, true)) {
            val profiles = Profiles()
            val h = Harness(store = profiles); h.ready(); h.tilt(); h.session.beginBoardCalibration()
            h.capturePose(BoardPose.CENTER, 0, 0)
            h.session.setBoardSensitivityPercent(BoardSensitivityControl.RIGHT, 50)
            profiles.interruptBefore = !after; profiles.interruptAfter = after
            h.session.saveBoardSensitivity()
            assertEquals("sensitivity_failed", h.session.snapshot.calibration.event)
            assertTrue(h.session.snapshot.calibration.canSaveSensitivity)
            assertTrue(h.session.snapshot.calibration.message.contains("interrupted"))
            profiles.interruptBefore = false; profiles.interruptAfter = false
            repeat(2) { h.session.saveBoardSensitivity() }
            assertEquals(1, profiles.writes)
            assertFalse(h.session.snapshot.calibration.canSaveSensitivity)
            assertEquals(listOf("CENTER"), h.session.snapshot.calibration.captured)
            assertTrue(h.session.snapshot.calibration.active)
            h.session.cancelBoardCalibration(); h.tilt()
            assertEquals(0.5f, h.session.snapshot.tilt.x, 0.0001f)
            val fresh = Harness(store = profiles); fresh.ready(); fresh.tilt()
            assertEquals(h.session.snapshot.tilt, fresh.session.snapshot.tilt)
            val other = Harness(store = profiles); other.ready("other-board"); other.tilt()
            assertEquals(1f, other.session.snapshot.tilt.x, 0.0001f)
        }
    }
    @Test fun sensitivityAndItsSaveAreFrozenDuringCaptureAndAfterLostTilt() {
        val profiles = Profiles()
        val h = Harness(store = profiles); h.ready(); h.tilt(); h.session.beginBoardCalibration()
        h.session.setBoardSensitivityPercent(BoardSensitivityControl.LEFT, 60)
        h.session.captureBoardCalibrationPose()
        h.session.setBoardSensitivityPercent(BoardSensitivityControl.LEFT, 150)
        h.session.saveBoardSensitivity()
        assertEquals(60, h.session.snapshot.calibration.sensitivity.percent(BoardSensitivityControl.LEFT))
        assertEquals(0, profiles.writes)
        h.clock += 1001; h.session.checkTiltFreshness()
        h.session.saveBoardSensitivity()
        assertEquals(0, profiles.writes)
        assertFalse(h.session.snapshot.calibration.active)
    }
    @Test fun sensitivityChangesKeepAcceptedPoseGeometryAndAreIncludedInCalibrationSave() {
        val profiles = Profiles()
        val h = Harness(store = profiles); h.ready(); h.tilt(); h.captureAll()
        h.session.setBoardSensitivityPercent(BoardSensitivityControl.RIGHT, 50)
        assertTrue(h.session.snapshot.calibration.canSave)
        h.session.saveBoardCalibration(); h.tilt()
        assertEquals(((0.5 - 0.08) / 0.92 * 0.5).toFloat(), h.session.snapshot.tilt.x, 0.0001f)
        assertEquals(0.5, profiles.values.getValue("test-board").sensitivity.right, 0.0)
        h.session.beginBoardCalibration()
        h.session.restoreImportedBoardCalibration(); h.tilt()
        h.session.beginBoardCalibration()
        assertEquals(BoardSensitivity(), h.session.snapshot.calibration.sensitivity)
    }
    @Test fun engineNeutralSnapshotPublishesEveryControlAndPreviewWithoutMovement() {
        val h = Harness(); h.ready(); h.tilt(); h.session.beginBoardCalibration()
        h.session.setBoardSensitivityPercent(BoardSensitivityControl.RIGHT, 75); h.tilt(50)
        val json = org.json.JSONObject(h.session.snapshot.toJson())
        assertEquals(0.0, json.getDouble("x"), 0.0)
        val state = json.getJSONObject("calibration")
        assertTrue(state.getDouble("preview_x") > 0)
        assertTrue(state.getBoolean("can_save_sensitivity"))
        val controls = state.getJSONArray("sensitivity_controls")
        assertEquals(5, controls.length())
        BoardSensitivityControl.entries.forEachIndexed { index, control ->
            val item = controls.getJSONObject(index)
            assertEquals(control.name, item.getString("id"))
            assertEquals(control.label, item.getString("label"))
            assertEquals(control.minimumPercent, item.getInt("minimum"))
            assertEquals(control.maximumPercent, item.getInt("maximum"))
            assertEquals(if (control == BoardSensitivityControl.RIGHT) 75 else BoardSensitivity().percent(control), item.getInt("percent"))
        }
    }
    @Test fun importedSensitivitySavesWithoutAnyCaptureAcrossBothWriteBoundaries() {
        val imported = BoardCalibration.fromJson(javaClass.getResourceAsStream("/bobo_board/default_calibration.json")!!.bufferedReader().use { it.readText() })
        for (after in listOf(false, true)) {
            val profiles = Profiles()
            val h = Harness(store = profiles, profile = imported); h.ready(); h.tilt()
            assertEquals(imported.sensitivity, h.session.snapshot.calibration.sensitivity)
            h.session.beginBoardCalibration()
            repeat(2) { h.session.setBoardSensitivityPercent(BoardSensitivityControl.RIGHT, 75) }
            h.session.setBoardSensitivityPercent(BoardSensitivityControl.DEAD_ZONE, 20)
            assertEquals(emptyList<String>(), h.session.snapshot.calibration.captured)
            assertFalse(h.session.snapshot.calibration.canSave)
            assertTrue(h.session.snapshot.calibration.canSaveSensitivity)
            profiles.interruptBefore = !after; profiles.interruptAfter = after
            h.session.saveBoardSensitivity()
            assertEquals("sensitivity_failed", h.session.snapshot.calibration.event)
            profiles.interruptBefore = false; profiles.interruptAfter = false
            repeat(2) { h.session.saveBoardSensitivity() }
            assertEquals(1, profiles.writes)
            val saved = profiles.values.getValue("test-board")
            assertTrue(saved.copy(sensitivity = imported.sensitivity).hasSameValues(imported))
            assertEquals(0.75, saved.sensitivity.right, 0.0)
            assertEquals(0.20, saved.sensitivity.deadZone, 0.0)
            val fresh = Harness(store = profiles, profile = imported); fresh.ready(); fresh.tilt()
            assertEquals(saved.sensitivity, fresh.session.snapshot.calibration.sensitivity)
            assertFalse(fresh.session.snapshot.calibration.active)
        }
    }

    companion object {
        private fun vector(x: Double, y: Double) = DoubleArray(9).apply { this[0] = x; this[1] = y }
        private fun calibration() = BoardCalibration(mapOf(
            BoardPose.CENTER to List(10) { vector(0.0, 0.0) },
            BoardPose.LEFT to List(10) { vector(-100.0, 0.0) },
            BoardPose.RIGHT to List(10) { vector(100.0, 0.0) },
            BoardPose.UP to List(10) { vector(0.0, 100.0) },
            BoardPose.DOWN to List(10) { vector(0.0, -100.0) },
        ), BoardSensitivity())
        private fun packet(x: Short, y: Short): ByteArray {
            val data = ByteArray(20); data[0] = 0x41; data[19] = 0x42
            ByteBuffer.wrap(data, 1, 18).order(ByteOrder.LITTLE_ENDIAN).putShort(x).putShort(y)
            return data
        }
    }
}
