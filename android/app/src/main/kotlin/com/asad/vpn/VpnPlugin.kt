package com.asad.vpn

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.VpnService
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

class VpnPlugin : MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private var activity: Activity? = null
    private val VPN_REQUEST_CODE = 1
    private var pendingResult: Result? = null
    private var pendingConfig: String? = null
    
    fun onAttachedToEngine(messenger: BinaryMessenger, activity: Activity) {
        this.activity = activity
        this.context = activity.applicationContext
        channel = MethodChannel(messenger, "com.asad.vpn/vpn")
        channel.setMethodCallHandler(this)
    }
    
    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "startVPN" -> {
                val config = call.argument<String>("config")
                if (config == null) {
                    result.error("INVALID_CONFIG", "Config is required", null)
                    return
                }
                
                pendingResult = result
                pendingConfig = config
                
                // Check VPN permission
                val intent = VpnService.prepare(context)
                if (intent != null) {
                    activity?.startActivityForResult(intent, VPN_REQUEST_CODE)
                } else {
                    startVpnService(config)
                    result.success(true)
                }
            }
            
            "stopVPN" -> {
                val intent = Intent(context, SingBoxVpnService::class.java).apply {
                    action = "STOP"
                }
                context.startService(intent)
                result.success(true)
            }
            
            "isConnected" -> {
                result.success(SingBoxVpnService.isRunning)
            }
            
            else -> {
                result.notImplemented()
            }
        }
    }
    
    private fun startVpnService(config: String) {
        val intent = Intent(context, SingBoxVpnService::class.java).apply {
            putExtra("config", config)
        }
        context.startService(intent)
    }
    
    fun handleActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == VPN_REQUEST_CODE) {
            if (resultCode == Activity.RESULT_OK) {
                pendingConfig?.let { 
                    startVpnService(it)
                    pendingResult?.success(true)
                }
            } else {
                pendingResult?.error("VPN_PERMISSION_DENIED", "User denied VPN permission", null)
            }
            pendingResult = null
            pendingConfig = null
        }
    }
    
    fun onDetachedFromEngine() {
        channel.setMethodCallHandler(null)
    }
}