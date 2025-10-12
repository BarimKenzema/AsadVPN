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
            Log.e(TAG, "❌ Error getting local IP: 
