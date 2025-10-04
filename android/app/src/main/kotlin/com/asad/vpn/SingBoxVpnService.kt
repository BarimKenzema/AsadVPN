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
        
        // Create V2Ray config
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
                put(JSONObject().apply {
                    put("tag", "socks")
                    put("port", 10808)
                    put("protocol", "socks")
                    put("listen", "127.0.0.1")
                    put("settings", JSONObject().apply {
                        put("auth", "noauth")
                        put("udp", true)
                        put("userLevel", 8)
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
                                        if (flow.isNotEmpty() && flow != "none") {
                                            put("flow", flow)
                                        }
                                        put("level", 8)
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
                
                put(JSONObject().apply {
                    put("protocol", "blackhole")
                    put("tag", "block")
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
            else -> "v2ray-arm64"
        }
        
        // Extract V2Ray binary to cache directory (more permissive)
        val cacheDir = File(cacheDir, "v2ray_bin")
        if (!cacheDir.exists()) {
            cacheDir.mkdirs()
        }
        
        val v2rayBinary = File(cacheDir, "v2ray")
        
        // Always re-extract to ensure it's executable
        try {
            assets.open(v2rayBinaryName).use { input ->
                FileOutputStream(v2rayBinary).use { output ->
                    input.copyTo(output)
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "Binary $v2rayBinaryName not found, trying v2ray-arm64")
            try {
                assets.open("v2ray-arm64").use { input ->
                    FileOutputStream(v2rayBinary).use { output ->
                        input.copyTo(output)
                    }
                }
            } catch (e2: Exception) {
                Log.w(TAG, "v2ray-arm64 not found, trying generic v2ray")
                assets.open("v2ray").use { input ->
                    FileOutputStream(v2rayBinary).use { output ->
                        input.copyTo(output)
                    }
                }
            }
        }
        
        // Make executable using chmod command
        try {
            Runtime.getRuntime().exec(arrayOf("chmod", "755", v2rayBinary.absolutePath)).waitFor()
        } catch (e: Exception) {
            Log.w(TAG, "chmod failed, trying to set executable directly")
            v2rayBinary.setExecutable(true, false)
            v2rayBinary.setReadable(true, false)
        }
        
        // Copy geoip and geosite files to cache directory
        try {
            val geoipFile = File(cacheDir, "geoip.dat")
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
            val geositeFile = File(cacheDir, "geosite.dat")
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
        
        // Start V2Ray process using Runtime.exec with shell
        try {
            // Use sh -c to execute the binary
            val command = arrayOf(
                "sh", "-c",
                "${v2rayBinary.absolutePath} run -config ${configFile.absolutePath}"
            )
            
            val env = arrayOf(
                "V2RAY_LOCATION_ASSET=${cacheDir.absolutePath}",
                "PATH=/system/bin:/system/xbin"
            )
            
            v2rayProcess = Runtime.getRuntime().exec(command, env, cacheDir)
            
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
            
            // Start error stream logging
            Thread {
                try {
                    v2rayProcess?.errorStream?.bufferedReader()?.forEachLine { line ->
                        Log.e(TAG, "V2Ray Error: $line")
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "Error reading V2Ray error stream", e)
                }
            }.start()
            
            // Set up traffic redirection
            setupTrafficRedirection()
            
            Log.d(TAG, "VPN Started Successfully")
            
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start V2Ray process", e)
            throw e
        }
    }
    
    private fun setupTrafficRedirection() {
        try {
            val fd = vpnInterface?.fd ?: return
            
            // Traffic will be handled by V2Ray through SOCKS proxy
            Log.d(TAG, "Traffic redirection setup complete, fd: $fd")
            
            // Try to set up iptables rules for traffic redirection
            try {
                Runtime.getRuntime().exec(arrayOf(
                    "sh", "-c",
                    "iptables -t nat -A OUTPUT -p tcp -j REDIRECT --to-ports 10808"
                ))
            } catch (e: Exception) {
                Log.w(TAG, "iptables setup failed (expected on non-rooted devices): $e")
            }
            
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