package com.example.asadvpn  // ⚠️ CHANGE THIS to your actual package name!

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.net.wifi.WifiManager
import android.os.Build
import android.telephony.TelephonyManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private val CHANNEL = "network_detector"
    private val PERMISSION_REQUEST_CODE = 1001

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getWiFiSSID" -> {
                    val ssid = getWiFiSSID()
                    result.success(ssid)
                }
                "getCarrierName" -> {
                    val carrier = getCarrierName()
                    result.success(carrier)
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
    }

    private fun getWiFiSSID(): String? {
        try {
            // Request permission if needed
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                if (ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION)
                    != PackageManager.PERMISSION_GRANTED) {
                    ActivityCompat.requestPermissions(
                        this,
                        arrayOf(Manifest.permission.ACCESS_FINE_LOCATION),
                        PERMISSION_REQUEST_CODE
                    )
                    return null
                }
            }

            val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            val wifiInfo = wifiManager.connectionInfo
            
            if (wifiInfo != null) {
                var ssid = wifiInfo.ssid
                
                // Remove quotes if present
                if (ssid != null && ssid.startsWith("\"") && ssid.endsWith("\"")) {
                    ssid = ssid.substring(1, ssid.length - 1)
                }
                
                // Return null for unknown SSID
                if (ssid == "<unknown ssid>" || ssid.isNullOrEmpty()) {
                    return null
                }
                
                return ssid
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
        return null
    }

    private fun getCarrierName(): String? {
        try {
            // Request permission if needed
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                if (ContextCompat.checkSelfPermission(this, Manifest.permission.READ_PHONE_STATE)
                    != PackageManager.PERMISSION_GRANTED) {
                    ActivityCompat.requestPermissions(
                        this,
                        arrayOf(Manifest.permission.READ_PHONE_STATE),
                        PERMISSION_REQUEST_CODE
                    )
                    return null
                }
            }

            val telephonyManager = getSystemService(Context.TELEPHONY_SERVICE) as TelephonyManager
            
            // Get carrier name
            var carrierName = telephonyManager.networkOperatorName
            
            // Fallback to SIM operator name if network operator is empty
            if (carrierName.isNullOrEmpty()) {
                carrierName = telephonyManager.simOperatorName
            }
            
            // Return null if still empty
            if (carrierName.isNullOrEmpty()) {
                return null
            }
            
            return carrierName
        } catch (e: Exception) {
            e.printStackTrace()
        }
        return null
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        
        when (requestCode) {
            PERMISSION_REQUEST_CODE -> {
                if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                    // Permission granted, you can now get WiFi SSID or carrier name
                    println("✅ Network detection permission granted")
                } else {
                    // Permission denied
                    println("⚠️ Network detection permission denied")
                }
            }
        }
    }
}
