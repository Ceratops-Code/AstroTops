package io.github.ceratops_code.boboboard

import android.Manifest
import android.bluetooth.*
import android.bluetooth.le.*
import android.content.Context
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import no.nordicsemi.android.ble.BleManager
import no.nordicsemi.android.ble.observer.ConnectionObserver
import java.util.UUID

/** Uses Nordic's maintained GATT queue. Android owns permissions and the radio;
 * this class owns only its own scan and GATT client, never other apps or adapters.
 */
internal class AndroidBoardRadio(private val context: Context) : BoardRadio {
    private val handler = Handler(Looper.getMainLooper())
    private val adapter get() = context.getSystemService(BluetoothManager::class.java)?.adapter
    private var scanner: BluetoothLeScanner? = null
    private var scan: ScanCallback? = null
    private var manager: BoardBleManager? = null
    private fun requireBluetooth() {
        check(listOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
            .all { context.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }) { "Allow Nearby devices access." }
        check(adapter?.isEnabled == true) { "Turn on Bluetooth to connect to BoBo." }
    }
    override fun scanForBoard(found: (String) -> Unit, failed: (String) -> Unit) {
        requireBluetooth()
        stopScanning()
        val callback = object : ScanCallback() {
            override fun onScanResult(type: Int, result: ScanResult) {
                if (scan !== this) return
                val name = result.scanRecord?.deviceName ?: result.device.name.orEmpty()
                val services = result.scanRecord?.serviceUuids.orEmpty()
                if (name.contains("BoBo", ignoreCase = true) || ParcelUuid(BoardBleManager.SERVICE) in services)
                    found(result.device.address)
            }
            override fun onScanFailed(code: Int) { if (scan === this) failed("BoBo Bluetooth scan failed (" + code + ").") }
        }
        scanner = checkNotNull(adapter?.bluetoothLeScanner) { "Bluetooth LE is unavailable." }
        scan = callback
        scanner!!.startScan(null, ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build(), callback)
    }
    override fun stopScanning() {
        val previous = scan; scan = null
        val previousScanner = scanner; scanner = null
        if (previous != null) runCatching { previousScanner?.stopScan(previous) }
    }
    override fun connectToBoard(address: String, events: BoardRadioEvents) {
        requireBluetooth()
        check(manager == null) { "Release the previous BoBo connection first." }
        val client = BoardBleManager(context, events)
        manager = client
        client.setConnectionObserver(object : ConnectionObserver {
            override fun onDeviceConnecting(device: BluetoothDevice) {}
            override fun onDeviceConnected(device: BluetoothDevice) {}
            override fun onDeviceReady(device: BluetoothDevice) { if (manager === client) events.ready() }
            override fun onDeviceFailedToConnect(device: BluetoothDevice, reason: Int) { if (manager === client) events.failed("BoBo connection failed (" + reason + ").") }
            override fun onDeviceDisconnecting(device: BluetoothDevice) {}
            override fun onDeviceDisconnected(device: BluetoothDevice, reason: Int) { if (manager === client) events.failed("BoBo disconnected (" + reason + ").") }
        })
        client.connect(checkNotNull(adapter).getRemoteDevice(address)).useAutoConnect(false).timeout(12000).enqueue()
    }
    override fun releaseBoard(released: (Boolean) -> Unit) {
        stopScanning()
        val old = manager; manager = null
        if (old == null) { released(true); return }
        var finished = false
        lateinit var timeout: Runnable
        fun finish(acknowledged: Boolean) {
            if (finished) return
            finished = true
            handler.removeCallbacks(timeout)
            old.close()
            released(acknowledged)
        }
        timeout = Runnable { finish(false) }
        handler.postDelayed(timeout, 2200)
        runCatching { old.disconnect().timeout(2000).done { finish(true) }.fail { _, _ -> finish(false) }.enqueue() }
            .onFailure { finish(false) }
    }
}

private class BoardBleManager(context: Context, private val events: BoardRadioEvents) : BleManager(context) {
    private var stream: BluetoothGattCharacteristic? = null
    private var battery: BluetoothGattCharacteristic? = null
    override fun isRequiredServiceSupported(gatt: BluetoothGatt): Boolean {
        stream = gatt.getService(SERVICE)?.getCharacteristic(STREAM)
        battery = gatt.getService(BATTERY)?.getCharacteristic(LEVEL)
        return stream != null && stream!!.properties.and(BluetoothGattCharacteristic.PROPERTY_NOTIFY) != 0
    }
    override fun initialize() {
        setNotificationCallback(stream).with { _, data -> data.value?.let { events.packet(it.copyOf()) } }
        enableNotifications(stream).timeout(8000).fail { _, code -> events.failed("BoBo notifications failed (" + code + ").") }.enqueue()
        battery?.let { value -> readCharacteristic(value).with { _, data ->
            data.value?.firstOrNull()?.let { events.battery(it.toInt() and 255) }
        }.enqueue() }
    }
    override fun onServicesInvalidated() { stream = null; battery = null }
    companion object {
        val SERVICE: UUID = UUID.fromString("856b152a-734a-5546-bf2b-ed4898184e12")
        private val STREAM = UUID.fromString("856b152b-734a-5546-bf2b-ed4898184e12")
        private val BATTERY = UUID.fromString("0000180f-0000-1000-8000-00805f9b34fb")
        private val LEVEL = UUID.fromString("00002a19-0000-1000-8000-00805f9b34fb")
    }
}
