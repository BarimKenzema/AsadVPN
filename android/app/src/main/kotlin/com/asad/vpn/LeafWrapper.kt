package com.asad.vpn

import android.util.Log

object LeafWrapper {
    private val TAG = "LeafWrapper"
    private var initialized = false
    
    init {
        try {
            System.loadLibrary("core")
            initialized = true
            Log.d(TAG, "Leaf/SingBox core library loaded successfully")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to load core library", e)
        }
    }
    
    // Native methods from libcore.so (sing-box)
    external fun startService(configContent: String): Boolean
    external fun stopService(): Boolean
    external fun testConfig(configContent: String): String
    
    fun start(configJson: String): Boolean {
        if (!initialized) {
            Log.e(TAG, "Core library not initialized")
            return false
        }
        
        return try {
            Log.d(TAG, "Starting Leaf/SingBox service")
            val result = startService(configJson)
            Log.d(TAG, "Start result: $result")
            result
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start service", e)
            false
        }
    }
    
    fun stop(): Boolean {
        if (!initialized) return false
        
        return try {
            val result = stopService()
            Log.d(TAG, "Service stopped: $result")
            result
        } catch (e: Exception) {
            Log.e(TAG, "Failed to stop service", e)
            false
        }
    }
    
    fun test(configJson: String): String {
        if (!initialized) return "Library not initialized"
        
        return try {
            testConfig(configJson)
        } catch (e: Exception) {
            "Test failed: ${e.message}"
        }
    }
}
