package com.asad.vpn

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.net.wifi.WifiInfo
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
                "getWiFiNetworkId" -> {
                    val networkId = getWiFiNetworkId()
                    result.success(networkId)
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

    private fun getWiFiNetworkId(): String? {
        try {
            val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            val wifiInfo: WifiInfo? = wifiManager.connectionInfo
            
            if (wifiInfo != null) {
                // Priority 1: Try to get BSSID (router MAC address - most reliable)
                var bssid = wifiInfo.bssid
                
                if (bssid != null && 
                    bssid.isNotEmpty() && 
                    bssid != "02:00:00:00:00:00" && 
                    bssid != "00:00:00:00:00:00" &&
                    bssid != "<unknown bssid>") {
                    
                    // Clean BSSID (remove colons for consistent format)
                    bssid = bssid.replace(":", "").lowercase()
                    println("✅ WiFi BSSID: $bssid")
                    return bssid
                }
                
                // Priority 2: Network ID (less reliable but works)
                val networkId = wifiInfo.networkId
                if (networkId != -1) {
                    println("⚠️ Using Network ID: $networkId (BSSID unavailable)")
                    return "netid_$networkId"
                }
                
                // Priority 3: Link speed + frequency as fallback
                val linkSpeed = wifiInfo.linkSpeed
                val frequency = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                    wifiInfo.frequency
                } else {
                    0
                }
                
                if (linkSpeed > 0 || frequency > 0) {
                    val identifier = "link_${linkSpeed}_${frequency}"
                    println("⚠️ Using link identifier: $identifier (BSSID and NetworkID unavailable)")
                    return identifier
                }
            }
            
            println("❌ Could not get any WiFi identifier")
        } catch (e: Exception) {
            println("❌ WiFi network ID error: ${e.message}")
            e.printStackTrace()
        }
        return null
    }

    private fun getCarrierName(): String? {
        try {
            // Request permission if needed (for carrier name on Android 10+)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                if (ContextCompat.checkSelfPermission(this, Manifest.permission.READ_PHONE_STATE)
                    != PackageManager.PERMISSION_GRANTED) {
                    // Return null if no permission (user can still use app with generic "Mobile Data")
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
                    println("✅ Phone state permission granted (carrier name available)")
                } else {
                    println("⚠️ Phone state permission denied (will show generic 'Mobile Data')")
                }
            }
        }
    }
}
