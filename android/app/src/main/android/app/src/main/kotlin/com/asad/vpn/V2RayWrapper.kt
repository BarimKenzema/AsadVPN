package com.asad.vpn

import android.util.Log

object V2RayWrapper {
    private val TAG = "V2RayWrapper"
    private var initialized = false
    
    init {
        try {
            System.loadLibrary("gojni")  // CHANGED: was "v2ray", now "gojni"
            initialized = true
            Log.d(TAG, "V2Ray (gojni) library loaded successfully")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to load V2Ray library", e)
        }
    }
    
    // JNI methods from libgojni.so (AndroidLibV2rayLite)
    external fun startV2rayWithJson(
        vpnInterfaceFd: Int,
        configJson: String,
        socksPort: Int
    ): Boolean
    
    external fun stopV2ray()
    
    external fun isRunning(): Boolean
    
    external fun queryStats(tag: String, direct: String): Long
    
    fun startV2Ray(vpnFd: Int, configJson: String): Boolean {
        if (!initialized) {
            Log.e(TAG, "V2Ray library not initialized")
            return false
        }
        
        return try {
            Log.d(TAG, "Starting V2Ray with VPN FD: $vpnFd")
            startV2rayWithJson(vpnFd, configJson, 10808)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start V2Ray", e)
            false
        }
    }
    
    fun stopV2Ray() {
        if (!initialized) return
        
        try {
            stopV2ray()
            Log.d(TAG, "V2Ray stopped")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to stop V2Ray", e)
        }
    }
}
