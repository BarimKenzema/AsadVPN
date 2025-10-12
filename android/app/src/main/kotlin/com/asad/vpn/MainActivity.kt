package com.asad.vpn

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.net.wifi.WifiInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.telephony.SubscriptionManager
import android.telephony.TelephonyManager
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.net.NetworkInterface

class MainActivity: FlutterActivity() {
    private val CHANNEL = "network_detector"
    private val PERMISSION_REQUEST_CODE = 1001
    private val TAG = "AsadVPN"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        Log.d(TAG, "🔵 Configuring Flutter Engine")
        
        // Request READ_PHONE_STATE permission for SIM detection
        requestPhoneStatePermission()
        
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            Log.d(TAG, "📞 Method call received: ${call.method}")
            
            when (call.method) {
                "getWiFiNetworkId" -> {
                    val networkId = getWiFiNetworkId()
                    Log.d(TAG, "📤 Returning WiFi Network ID: $networkId")
                    result.success(networkId)
                }
                "getCarrierName" -> {
                    val carrier = getCarrierName()
                    Log.d(TAG, "📤 Returning Carrier: $carrier")
                    result.success(carrier)
                }
                else -> {
                    Log.d(TAG, "⚠️ Method not implemented: ${call.method}")
                    result.notImplemented()
                }
            }
        }
    }

    private fun requestPhoneStatePermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.READ_PHONE_STATE)
                != PackageManager.PERMISSION_GRANTED) {
                Log.d(TAG, "📱 Requesting READ_PHONE_STATE permission...")
                ActivityCompat.requestPermissions(
                    this,
                    arrayOf(Manifest.permission.READ_PHONE_STATE),
                    PERMISSION_REQUEST_CODE
                )
            } else {
                Log.d(TAG, "✅ READ_PHONE_STATE permission already granted")
            }
        }
    }

    private fun getLocalIPAddress(): String? {
        try {
            val interfaces = NetworkInterface.getNetworkInterfaces()
            while (interfaces.hasMoreElements()) {
                val networkInterface = interfaces.nextElement()
                val addresses = networkInterface.inetAddresses
                
                while (addresses.hasMoreElements()) {
                    val address = addresses.nextElement()
                    
                    // Skip loopback and IPv6
                    if (!address.isLoopbackAddress && address.address.size == 4) {
                        val ip = address.hostAddress
                        Log.d(TAG, "   Found IP: $ip on interface ${networkInterface.name}")
                        
                        // Return first valid IPv4 (usually WiFi or mobile data)
                        if (ip != null && ip.contains(".")) {
                            return ip
                        }
                    }
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error getting local IP: ${e.message}", e)
        }
        return null
    }

    private fun getWiFiNetworkId(): String? {
        Log.d(TAG, "🔍 Getting WiFi Network ID...")
        
        try {
            val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            Log.d(TAG, "✅ WifiManager obtained")
            
            val wifiInfo: WifiInfo? = wifiManager.connectionInfo
            
            if (wifiInfo == null) {
                Log.e(TAG, "❌ WifiInfo is NULL!")
                return null
            }
            
            Log.d(TAG, "✅ WifiInfo obtained")
            Log.d(TAG, "   Network ID: ${wifiInfo.networkId}")
            Log.d(TAG, "   BSSID (raw): ${wifiInfo.bssid}")
            Log.d(TAG, "   SSID (raw): ${wifiInfo.ssid}")
            Log.d(TAG, "   Link Speed: ${wifiInfo.linkSpeed}")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                Log.d(TAG, "   Frequency: ${wifiInfo.frequency}")
            }
            
            // Priority 1: Try to get BSSID (router MAC address - most reliable)
            var bssid = wifiInfo.bssid
            
            Log.d(TAG, "🔍 Checking BSSID: '$bssid'")
            
            if (bssid != null && 
                bssid.isNotEmpty() && 
                bssid != "02:00:00:00:00:00" && 
                bssid != "00:00:00:00:00:00" &&
                bssid != "<unknown bssid>") {
                
                // Clean BSSID (remove colons for consistent format)
                val originalBssid = bssid
                bssid = bssid.replace(":", "").lowercase()
                
                Log.d(TAG, "✅ BSSID SUCCESS!")
                Log.d(TAG, "   Original: $originalBssid")
                Log.d(TAG, "   Cleaned: $bssid")
                
                return bssid
            } else {
                Log.w(TAG, "⚠️ BSSID is invalid or unavailable: '$bssid'")
            }
            
            // Priority 2: Network ID (less reliable but works)
            val networkId = wifiInfo.networkId
            Log.d(TAG, "🔍 Checking Network ID: $networkId")
            
            if (networkId != -1) {
                val result = "netid_$networkId"
                Log.d(TAG, "✅ Using Network ID: $result")
                return result
            } else {
                Log.w(TAG, "⚠️ Network ID is -1 (invalid)")
            }
            
            // Priority 3: Gateway IP + DNS + LOCAL IP (NEW - Makes WiFi unique!)
            Log.d(TAG, "🔍 Trying Gateway+DNS+LocalIP method...")
            val gatewayDns = getGatewayAndDNSWithLocalIP()
            if (gatewayDns != null) {
                Log.d(TAG, "✅ Using Gateway+DNS+LocalIP: $gatewayDns")
                return gatewayDns
            }
            
            // Priority 4: Fallback to null (no generic!)
            Log.w(TAG, "⚠️ All WiFi identifiers failed, returning null")
            return null
            
        } catch (e: Exception) {
            Log.e(TAG, "❌ WiFi network ID error: ${e.message}", e)
            e.printStackTrace()
        }
        
        Log.e(TAG, "❌ Returning NULL for WiFi Network ID")
        return null
    }

    private fun getGatewayAndDNSWithLocalIP(): String? {
        try {
            val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            val dhcpInfo = wifiManager.dhcpInfo
            
            // Get Gateway IP
            val gatewayInt = dhcpInfo.gateway
            if (gatewayInt == 0) {
                Log.w(TAG, "⚠️ Gateway IP is 0 (invalid)")
                return null
            }
            
            val gatewayIP = String.format(
                "%d.%d.%d.%d",
                gatewayInt and 0xFF,
                gatewayInt shr 8 and 0xFF,
                gatewayInt shr 16 and 0xFF,
                gatewayInt shr 24 and 0xFF
            )
            
            // Get DNS1
            val dns1Int = dhcpInfo.dns1
            val dns1IP = if (dns1Int != 0) {
                String.format(
                    "%d.%d.%d.%d",
                    dns1Int and 0xFF,
                    dns1Int shr 8 and 0xFF,
                    dns1Int shr 16 and 0xFF,
                    dns1Int shr 24 and 0xFF
                )
            } else {
                "0.0.0.0"
            }
            
            // Get DNS2
            val dns2Int = dhcpInfo.dns2
            val dns2IP = if (dns2Int != 0) {
                String.format(
                    "%d.%d.%d.%d",
                    dns2Int and 0xFF,
                    dns2Int shr 8 and 0xFF,
                    dns2Int shr 16 and 0xFF,
                    dns2Int shr 24 and 0xFF
                )
            } else {
                "0.0.0.0"
            }
            
            // Get Local IP (THIS IS THE KEY - makes each WiFi unique!)
            val localIP = getLocalIPAddress() ?: "0.0.0.0"
            
            Log.d(TAG, "   Gateway: $gatewayIP")
            Log.d(TAG, "   DNS1: $dns1IP")
            Log.d(TAG, "   DNS2: $dns2IP")
            Log.d(TAG, "   Local IP: $localIP")
            
            // Combine Gateway + DNS + LOCAL IP for unique identifier
            val combined = "gw_${gatewayIP}_dns_${dns1IP}_${dns2IP}_localIP_${localIP}"
            
            Log.d(TAG, "✅ Gateway+DNS+LocalIP identifier: $combined")
            return combined
            
        } catch (e: Exception) {
            Log.e(TAG, "❌ Gateway+DNS+LocalIP error: ${e.message}", e)
            return null
        }
    }

    private fun getCarrierName(): String? {
        Log.d(TAG, "🔍 Getting Carrier Name...")
        
        try {
            // Check permission first
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.READ_PHONE_STATE)
                != PackageManager.PERMISSION_GRANTED) {
                Log.w(TAG, "⚠️ READ_PHONE_STATE permission not granted")
                return null
            }

            val telephonyManager = getSystemService(Context.TELEPHONY_SERVICE) as TelephonyManager
            
            // NEW: Get carrier from ACTIVE DATA SUBSCRIPTION + SIM SLOT
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP_MR1) {
                try {
                    val subscriptionManager = getSystemService(Context.TELEPHONY_SUBSCRIPTION_SERVICE) as SubscriptionManager
                    
                    // Get default data subscription ID
                    val dataSubId = SubscriptionManager.getDefaultDataSubscriptionId()
                    Log.d(TAG, "   Default Data Subscription ID: $dataSubId")
                    
                    if (dataSubId != SubscriptionManager.INVALID_SUBSCRIPTION_ID) {
                        val activeSubInfo = subscriptionManager.getActiveSubscriptionInfo(dataSubId)
                        
                        if (activeSubInfo != null) {
                            var carrierName = activeSubInfo.carrierName?.toString()
                            val slotIndex = activeSubInfo.simSlotIndex
                            
                            Log.d(TAG, "   Active Data SIM Carrier: '$carrierName'")
                            Log.d(TAG, "   SIM Slot Index: $slotIndex")
                            
                            if (!carrierName.isNullOrEmpty()) {
                                // Include slot index to differentiate SIMs with same carrier
                                val result = "${carrierName}_Slot${slotIndex}"
                                Log.d(TAG, "✅ Carrier (from active data SIM): $result")
                                return result
                            }
                        } else {
                            Log.w(TAG, "⚠️ Active subscription info is null")
                        }
                    } else {
                        Log.w(TAG, "⚠️ Invalid subscription ID")
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "❌ Error getting active subscription: ${e.message}")
                }
            }
            
            // FALLBACK: Try network operator (old method)
            var carrierName = telephonyManager.networkOperatorName
            Log.d(TAG, "   Network Operator: '$carrierName'")
            
            // Fallback to SIM operator name if network operator is empty
            if (carrierName.isNullOrEmpty()) {
                carrierName = telephonyManager.simOperatorName
                Log.d(TAG, "   SIM Operator: '$carrierName'")
            }
            
            // Return null if still empty
            if (carrierName.isNullOrEmpty()) {
                Log.w(TAG, "⚠️ Carrier name is empty")
                return null
            }
            
            Log.d(TAG, "✅ Carrier (fallback): $carrierName")
            return carrierName
        } catch (e: Exception) {
            Log.e(TAG, "❌ Carrier error: ${e.message}", e)
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
                    Log.d(TAG, "✅ Phone state permission granted")
                } else {
                    Log.w(TAG, "⚠️ Phone state permission denied")
                }
            }
        }
    }
}
