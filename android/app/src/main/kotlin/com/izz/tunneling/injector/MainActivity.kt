package com.izz.tunneling.injector

import android.app.Activity
import android.content.Intent
import android.net.VpnService
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val VPN_REQUEST_CODE = 9921
    private var pendingConfigJson: String? = null
    private var pendingResult: MethodChannel.Result? = null

    companion object {
        const val CHANNEL_NAME = "com.izz.tunneling/vpn"
        var channel: MethodChannel? = null

        fun notifyStateChange(state: String) {
            channel?.invokeMethod("onStateChanged", state)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_NAME)
        channel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "startVpn" -> {
                    val config = call.argument<String>("config") ?: ""
                    handleStartVpn(config, result)
                }
                "stopVpn" -> {
                    val stopIntent = Intent(this, IzzVpnService::class.java).apply {
                        action = IzzVpnService.ACTION_STOP
                    }
                    startService(stopIntent)
                    result.success(true)
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
            }
            pendingConfigJson = null
            pendingResult = null
        }
    }
}
