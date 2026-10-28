package com.izz.tunneling.injector

import android.app.Activity
import android.content.Intent
import android.net.VpnService
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val VPN_REQUEST_CODE = 9921
    private var pendingConfigJson: String? = null
    private var pendingResult: MethodChannel.Result? = null

    companion object {
        const val TAG = "IzzMainActivity"
        const val CHANNEL_NAME = "com.izz.tunneling/vpn"
        var channel: MethodChannel? = null
        private val mainHandler = Handler(Looper.getMainLooper())

        /**
         * Notify Flutter of VPN state changes.
         * @param state One of: "connecting", "authenticating", "connected", "disconnected", "error"
         * @param message Optional error/status message for context
         */
        fun notifyStateChange(state: String, message: String? = null) {
            mainHandler.post {
                try {
                    val payload = if (message != null) {
                        mapOf("state" to state, "message" to message)
                    } else {
                        mapOf("state" to state)
                    }
                    channel?.invokeMethod("onStateChanged", payload)
                    Log.d(TAG, "State change notified: $state${if (message != null) " ($message)" else ""}")
                } catch (e: Exception) {
                    Log.e(TAG, "Failed to notify state change: ${e.message}")
                }
            }
        }

        fun notifyStats(stats: Map<String, Any>) {
            mainHandler.post {
                try {
                    channel?.invokeMethod("onStats", stats)
                } catch (_: Exception) {}
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_NAME)
        channel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "startVpn" -> {
                    val config = call.argument<String>("config") ?: ""
                    if (config.isBlank()) {
                        result.error("INVALID_CONFIG", "Config JSON is empty", null)
                        return@setMethodCallHandler
                    }
                    handleStartVpn(config, result)
                }
                "stopVpn" -> {
                    val stopIntent = Intent(this, IzzVpnService::class.java).apply {
                        action = IzzVpnService.ACTION_STOP
                    }
                    startService(stopIntent)
                    result.success(true)
                }
                "getVpnState" -> {
                    val instance = IzzVpnService.instance
                    if (instance != null) {
                        result.success("connected")
                    } else {
                        result.success("disconnected")
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun handleStartVpn(configJson: String, result: MethodChannel.Result) {
        val vpnIntent = VpnService.prepare(this)
        if (vpnIntent != null) {
            pendingConfigJson = configJson
            pendingResult = result
            startActivityForResult(vpnIntent, VPN_REQUEST_CODE)
        } else {
            startVpnServiceDirectly(configJson)
            // Return true to indicate the start command was accepted.
            // Actual connection state will come via onStateChanged callback.
            result.success(true)
        }
    }

    private fun startVpnServiceDirectly(configJson: String) {
        val intent = Intent(this, IzzVpnService::class.java).apply {
            action = IzzVpnService.ACTION_START
            putExtra("CONFIG_JSON", configJson)
        }
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == VPN_REQUEST_CODE) {
            if (resultCode == Activity.RESULT_OK) {
                pendingConfigJson?.let { startVpnServiceDirectly(it) }
                pendingResult?.success(true)
            } else {
                pendingResult?.success(false)
                notifyStateChange("disconnected", "Izin VPN ditolak pengguna")
            }
            pendingConfigJson = null
            pendingResult = null
        }
    }

    override fun onDestroy() {
        channel = null
        super.onDestroy()
    }
}
