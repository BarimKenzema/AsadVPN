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
    private var tun2socksProcess: Process? = null
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
            .addAddress("10.0.0.2", 32)
            .addRoute("0.0.0.0", 0)
            .addDnsServer("8.8.8.8")
            .addDnsServer("8.8.4.4")
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
            
            put("inbounds", JSONArray().apply {
                put(JSONObject().apply {
                    put("port", 10808)
                    put("protocol", "socks")
                    put("listen", "127.0.0.1")
                    put("settings", JSONObject().apply {
                        put("auth", "noauth")
                        put("udp", true)
                    })
                })
            })
            
            put("outbounds", JSONArray().apply {
                put(JSONObject().apply {
                    put("protocol", "vless")
                    put("settings", JSONObject().apply {
                        put("vnext", JSONArray().apply {
                            put(JSONObject().apply {
                                put("address", host)
                                put("port", port)
                                put("users", JSONArray().apply {
                                    put(JSONObject().apply {
                                        put("id", uuid)
                                        put("encryption", encryption)
                                        put("flow", flow)
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
                    })
                })
            })
        }
        
        // Write config to file
        val configFile = File(filesDir, "config.json")
        FileOutputStream(configFile).use {
            it.write(v2rayConfig.toString().toByteArray())
        }
        
        // Extract correct binary based on device architecture
        val abi = android.os.Build.SUPPORTED_ABIS[0]
        val v2rayBinaryName = when {
            abi.contains("arm64") -> "v2ray-arm64"
            abi.contains("armeabi") -> "v2ray-arm32"
            else -> "v2ray-arm64" // fallback
        }
        val tun2socksName = when {
            abi.contains("arm64") -> "tun2socks-arm64"
            abi.contains("armeabi") -> "tun2socks-arm32"
            else -> "tun2socks-arm64" // fallback
        }
        
        val v2rayBinary = File(filesDir, "v2ray")
        if (!v2rayBinary.exists()) {
            assets.open(v2rayBinaryName).use { input ->
                FileOutputStream(v2rayBinary).use { output ->
                    input.copyTo(output)
                }
            }
            v2rayBinary.setExecutable(true)
        }
        
        // Similarly for tun2socks
        val tun2socksBinary = File(filesDir, "tun2socks")
        if (!tun2socksBinary.exists()) {
            assets.open(tun2socksName).use { input ->
                FileOutputStream(tun2socksBinary).use { output ->
                    input.copyTo(output)
                }
            }
            tun2socksBinary.setExecutable(true)
        }
        
        // Copy geoip and geosite files if needed
        val geoipFile = File(filesDir, "geoip.dat")
        if (!geoipFile.exists()) {
            assets.open("geoip.dat").use { input ->
                FileOutputStream(geoipFile).use { output ->
                    input.copyTo(output)
                }
            }
        }
        
        val geositeFile = File(filesDir, "geosite.dat")
        if (!geositeFile.exists()) {
            assets.open("geosite.dat").use { input ->
                FileOutputStream(geositeFile).use { output ->
                    input.copyTo(output)
                }
            }
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
        
        // Wait a bit for V2Ray to start
        Thread.sleep(1000)
        
        // Start TUN2SOCKS to redirect VPN traffic to V2Ray
        startTun2Socks()
        
        Log.d(TAG, "VPN Started Successfully")
    }
    
    private fun startTun2Socks() {
        try {
            val tun2socksBinary = File(filesDir, "tun2socks")
            val fd = vpnInterface?.fd ?: return
            
            // Simple tun2socks command
            val cmd = arrayOf(
                tun2socksBinary.absolutePath,
                "-device", "fd://${fd}",
                "-proxy", "socks5://127.0.0.1:10808",
                "-interface", "tun0"
            )
            
            tun2socksProcess = Runtime.getRuntime().exec(cmd)
            Log.d(TAG, "TUN2SOCKS started")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start tun2socks", e)
        }
    }
    
    private fun stopVPN() {
        try {
            isRunning = false
            tun2socksProcess?.destroy()
            tun2socksProcess = null
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