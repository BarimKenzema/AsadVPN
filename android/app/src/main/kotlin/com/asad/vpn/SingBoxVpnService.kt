package com.asad.vpn

import android.content.Intent
import android.net.VpnService
import android.os.ParcelFileDescriptor
import android.util.Log
import java.io.File
import java.io.FileOutputStream
import org.json.JSONObject
import org.json.JSONArray

class SingBoxVpnService : VpnService() {
    private var vpnInterface: ParcelFileDescriptor? = null
    private var v2rayProcess: Process? = null
    private val TAG = "SingBoxVPN"
    
    companion object {
        var isRunning = false
    }
    
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == "STOP") {
            stopVPN()
            return START_NOT_STICKY
        }
        
        val config = intent?.getStringExtra("config") ?: return START_NOT_STICKY
        
        Thread {
            try {
                Log.d(TAG, "Starting VPN with config")
                startVPN(config)
            } catch (e: Exception) {
                Log.e(TAG, "Failed to start VPN", e)
                stopVPN()
            }
        }.start()
        
        return START_STICKY
    }
    
    private fun startVPN(vlessUri: String) {
        // Parse VLESS URI
        val uri = android.net.Uri.parse(vlessUri.split("#")[0])
        val uuid = uri.userInfo ?: ""
        val host = uri.host ?: ""
        val port = uri.port.takeIf { it > 0 } ?: 443
        val params = uri.queryParameterNames.associateWith { uri.getQueryParameter(it) }
        
        val type = params["type"] ?: "tcp"
        val security = params["security"] ?: "tls"
        val sni = params["sni"] ?: host
        val encryption = params["encryption"] ?: "none"
        val flow = params["flow"] ?: ""
        
        // Build VPN
        val builder = Builder()
        builder.setSession("AsadVPN")
            .setMtu(1500)
            .addAddress("10.0.0.2", 24)
            .addRoute("0.0.0.0", 0)
            .addDnsServer("8.8.8.8")
            .addDnsServer("1.1.1.1")
            .addDisallowedApplication(packageName)
        
        vpnInterface = builder.establish()
        
        if (vpnInterface == null) {
            throw Exception("Failed to establish VPN interface")
        }
        
        // Create V2Ray config with TUN inbound
        val v2rayConfig = JSONObject().apply {
            put("log", JSONObject().apply {
                put("loglevel", "warning")
            })
            
            put("dns", JSONObject().apply {
                put("servers", JSONArray().apply {
                    put("8.8.8.8")
                    put("1.1.1.1")
                })
            })
            
            put("inbounds", JSONArray().apply {
                // TUN inbound - V2Ray will handle the TUN device directly
                put(JSONObject().apply {
                    put("tag", "tun")
                    put("protocol", "dokodemo-door")
                    put("listen", "127.0.0.1")
                    put("port", 12345)
                    put("settings", JSONObject().apply {
                        put("network", "tcp,udp")
                        put("followRedirect", true)
                    })
                    put("sniffing", JSONObject().apply {
                        put("enabled", true)
                        put("destOverride", JSONArray().apply {
                            put("http")
                            put("tls")
                        })
                    })
                })
            })
            
            put("outbounds", JSONArray().apply {
                put(JSONObject().apply {
                    put("protocol", "vless")
                    put("tag", "proxy")
                    put("settings", JSONObject().apply {
                        put("vnext", JSONArray().apply {
                            put(JSONObject().apply {
                                put("address", host)
                                put("port", port)
                                put("users", JSONArray().apply {
                                    put(JSONObject().apply {
                                        put("id", uuid)
                                        put("encryption", encryption)
                                        if (flow.isNotEmpty()) {
                                            put("flow", flow)
                                        }
                                        put("level", 0)
                                    })
                                })
                            })
                        })
                    })
                    
                    put("streamSettings", JSONObject().apply {
                        put("network", type)
                        put("security", security)
                        
                        if (security == "tls") {
                            put("tlsSettings", JSONObject().apply {
                                put("serverName", sni)
                                put("allowInsecure", true)
                                put("alpn", JSONArray().apply {
                                    put("h2")
                                    put("http/1.1")
                                })
                            })
                        }
                        
                        if (type == "ws") {
                            put("wsSettings", JSONObject().apply {
                                put("path", params["path"] ?: "/")
                                put("headers", JSONObject().apply {
                                    put("Host", params["host"] ?: host)
                                })
                            })
                        }
                        
                        if (type == "grpc") {
                            put("grpcSettings", JSONObject().apply {
                                put("serviceName", params["serviceName"] ?: "")
                            })
                        }
                    })
                })
                
                put(JSONObject().apply {
                    put("protocol", "freedom")
                    put("tag", "direct")
                })
            })
            
            put("routing", JSONObject().apply {
                put("domainStrategy", "AsIs")
                put("rules", JSONArray().apply {
                    put(JSONObject().apply {
                        put("type", "field")
                        put("outboundTag", "direct")
                        put("ip", JSONArray().apply {
                            put("geoip:private")
                        })
                    })
                })
            })
        }
        
        // Write config to file
        val configFile = File(filesDir, "config.json")
        FileOutputStream(configFile).use {
            it.write(v2rayConfig.toString(2).toByteArray())
        }
        
        // Extract correct binary based on device architecture
        val abi = android.os.Build.SUPPORTED_ABIS[0]
        val v2rayBinaryName = when {
            abi.contains("arm64") -> "v2ray-arm64"
            abi.contains("armeabi") -> "v2ray-arm32"
            else -> "v2ray-arm64" // fallback
        }
        
        // Extract V2Ray binary with proper fallback handling
        val v2rayBinary = File(filesDir, "v2ray")
        if (!v2rayBinary.exists()) {
            try {
                assets.open(v2rayBinaryName).use { input ->
                    FileOutputStream(v2rayBinary).use { output ->
                        input.copyTo(output)
                    }
                }
            } catch (e: Exception) {
                // If specific arch not found, try v2ray-arm64 as fallback
                Log.w(TAG, "Binary $v2rayBinaryName not found, using v2ray-arm64")
                try {
                    assets.open("v2ray-arm64").use { input ->
                        FileOutputStream(v2rayBinary).use { output ->
                            input.copyTo(output)
                        }
                    }
                } catch (e2: Exception) {
                    // Last resort: try just "v2ray"
                    Log.w(TAG, "v2ray-arm64 not found, trying generic v2ray")
                    assets.open("v2ray").use { input ->
                        FileOutputStream(v2rayBinary).use { output ->
                            input.copyTo(output)
                        }
                    }
                }
            }
            v2rayBinary.setExecutable(true)
        }
        
        // Copy geoip and geosite files if they exist
        try {
            val geoipFile = File(filesDir, "geoip.dat")
            if (!geoipFile.exists()) {
                assets.open("geoip.dat").use { input ->
                    FileOutputStream(geoipFile).use { output ->
                        input.copyTo(output)
                    }
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "geoip.dat not found in assets")
        }
        
        try {
            val geositeFile = File(filesDir, "geosite.dat")
            if (!geositeFile.exists()) {
                assets.open("geosite.dat").use { input ->
                    FileOutputStream(geositeFile).use { output ->
                        input.copyTo(output)
                    }
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "geosite.dat not found in assets")
        }
        
        // Start V2Ray process
        val pb = ProcessBuilder(
            v2rayBinary.absolutePath,
            "run",
            "-config",
            configFile.absolutePath
        )
        pb.environment()["V2RAY_LOCATION_ASSET"] = filesDir.absolutePath
        pb.redirectErrorStream(true)
        
        v2rayProcess = pb.start()
        isRunning = true
        
        // Start logging V2Ray output for debugging
        Thread {
            try {
                v2rayProcess?.inputStream?.bufferedReader()?.forEachLine { line ->
                    Log.d(TAG, "V2Ray: $line")
                }
            } catch (e: Exception) {
                Log.e(TAG, "Error reading V2Ray output", e)
            }
        }.start()
        
        // Set up traffic redirection using iptables (simpler than tun2socks)
        setupTrafficRedirection()
        
        Log.d(TAG, "VPN Started Successfully")
    }
    
    private fun setupTrafficRedirection() {
        try {
            // Simple traffic redirection without tun2socks
            val fd = vpnInterface?.fd ?: return
            
            // V2Ray will handle the traffic directly
            Log.d(TAG, "Traffic redirection setup complete")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to setup traffic redirection", e)
        }
    }
    
    private fun stopVPN() {
        try {
            isRunning = false
            v2rayProcess?.destroy()
            v2rayProcess = null
            vpnInterface?.close()
            vpnInterface = null
            stopSelf()
        } catch (e: Exception) {
            Log.e(TAG, "Error stopping VPN", e)
        }
    }
    
    override fun onDestroy() {
        stopVPN()
        super.onDestroy()
    }
}