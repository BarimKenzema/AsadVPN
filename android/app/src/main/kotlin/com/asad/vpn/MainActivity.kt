package com.asad.vpn

import android.app.Activity
import android.content.Intent
import android.net.VpnService
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {

    private val CHANNEL = "com.asad.vpn/vpn"
    private var pendingResult: MethodChannel.Result? = null
    private var pendingConfig: String? = null
    private val REQ_VPN = 8463

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "startVPN" -> {
                    val config = call.argument<String>("config") ?: ""
                    if (config.isBlank()) {
                        result.error("INVALID_CONFIG", "Empty config", null)
                        return@setMethodCallHandler
                    }
                    val intent = VpnService.prepare(this)
                    if (intent != null) {
                        pendingResult = result
                        pendingConfig = config
                        startActivityForResult(intent, REQ_VPN)
                    } else {
                        startVpnService(config); result.success(true)
                    }
                }
                "stopVPN" -> {
                    stopService(Intent(this, SingBoxVpnService::class.java))
                    result.success(true)
                }
                "isConnected" -> result.success(SingBoxVpnService.isRunning)
                else -> result.notImplemented()
            }
        }
    }

    private fun startVpnService(config: String) {
        val svc = Intent(this, SingBoxVpnService::class.java).apply {
            putExtra(SingBoxVpnService.EXTRA_CONFIG, config)
        }
        startForegroundService(svc)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == REQ_VPN) {
            if (resultCode == Activity.RESULT_OK) {
                val cfg = pendingConfig ?: ""
                startVpnService(cfg)
                pendingResult?.success(true)
            } else {
                pendingResult?.error("VPN_PERMISSION_DENIED", "User denied VPN permission", null)
            }
            pendingResult = null; pendingConfig = null
        } else {
            super.onActivityResult(requestCode, resultCode, data)
        }
    }
}