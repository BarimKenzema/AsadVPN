package com.asad.vpn

import android.content.Intent
import android.net.VpnService
import android.os.ParcelFileDescriptor
import android.util.Log
import org.json.JSONObject
import org.json.JSONArray

class SingBoxVpnService : VpnService() {
    private var vpnInterface: ParcelFileDescriptor? = null
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
        
        Log.d(TAG, "Parsed: host=$host, port=$port, type=$type, security=$security")
        
        // Build VPN
        val builder = Builder()
        builder.setSession("AsadVPN")
            .setMtu(1500)
            .addAddress("172.19.0.1", 30)
            .addRoute("0.0.0.0", 0)
            .addDnsServer("8.8.8.8")
            .addDnsServer("1.1.1.1")
            .addDisallowedApplication(packageName)
        
        vpnInterface = builder.establish()
        
        if (vpnInterface == null) {
            throw Exception("Failed to establish VPN interface")
        }
        
        val vpnFd = vpnInterface!!.fd
        Log.d(TAG, "VPN interface established, FD: $vpnFd")
        
        // Create sing-box config (simpler than V2Ray)
        val singBoxConfig = JSONObject().apply {
            // Log settings
            put("log", JSONObject().apply {
                put("level", "info")
                put("timestamp", true)
            })
            
            // DNS settings
            put("dns", JSONObject().apply {
                put("servers", JSONArray().apply {
                    put(JSONObject().apply {
                        put("tag", "google")
                        put("address", "8.8.8.8")
                    })
                    put(JSONObject().apply {
                        put("tag", "local")
                        put("address", "223.5.5.5")
                        put("detour", "direct")
                    })
                })
                put("rules", JSONArray())
                put("final", "google")
            })
            
            // Inbound - TUN device
            put("inbounds", JSONArray().apply {
                put(JSONObject().apply {
                    put("type", "tun")
                    put("tag", "tun-in")
                    put("inet4_address", "172.19.0.1/30")
                    put("auto_route", true)
                    put("strict_route", false)
                    put("stack", "gvisor")
                    put("sniff", true)
                })
            })
            
            // Outbound - VLESS server
            put("outbounds", JSONArray().apply {
                // Main VLESS outbound
                put(JSONObject().apply {
                    put("type", "vless")
                    put("tag", "proxy")
                    put("server", host)
                    put("server_port", port)
                    put("uuid", uuid)
                    
                    // Flow settings
                    if (flow.isNotEmpty() && flow != "none") {
                        put("flow", flow)
                    }
                    
                    // TLS settings
                    if (security == "tls") {
                        put("tls", JSONObject().apply {
                            put("enabled", true)
                            put("server_name", sni)
                            put("insecure", true)
                            put("alpn", JSONArray().apply {
                                put("h2")
                                put("http/1.1")
                            })
                        })
                    }
                    
                    // Transport settings
                    put("transport", JSONObject().apply {
                        when (type) {
                            "ws" -> {
                                put("type", "ws")
                                put("path", params["path"] ?: "/")
                                params["host"]?.let { wsHost ->
                                    put("headers", JSONObject().apply {
                                        put("Host", wsHost)
                                    })
                                }
                            }
                            "grpc" -> {
                                put("type", "grpc")
                                put("service_name", params["serviceName"] ?: "")
                            }
                            "http" -> {
                                put("type", "http")
                                params["host"]?.let { httpHost ->
                                    put("host", JSONArray().apply {
                                        put(httpHost)
                                    })
                                }
                                params["path"]?.let { httpPath ->
                                    put("path", httpPath)
                                }
                            }
                        }
                    })
                })
                
                // Direct outbound
                put(JSONObject().apply {
                    put("type", "direct")
                    put("tag", "direct")
                })
                
                // Block outbound
                put(JSONObject().apply {
                    put("type", "block")
                    put("tag", "block")
                })
            })
            
            // Routing rules
            put("route", JSONObject().apply {
                put("auto_detect_interface", true)
                put("rules", JSONArray().apply {
                    // Private IPs go direct
                    put(JSONObject().apply {
                        put("ip_cidr", JSONArray().apply {
                            put("224.0.0.0/3")
                            put("ff00::/8")
                        })
                        put("outbound", "block")
                    })
                    put(JSONObject().apply {
                        put("ip_cidr", JSONArray().apply {
                            put("10.0.0.0/8")
                            put("172.16.0.0/12")
                            put("192.168.0.0/16")
                        })
                        put("outbound", "direct")
                    })
                })
                put("final", "proxy")
            })
        }
        
        val configJson = singBoxConfig.toString(2)
        Log.d(TAG, "Sing-box config generated, length: ${configJson.length}")
        
        // Start service using Leaf/SingBox library
        val success = LeafWrapper.start(configJson)
        
        if (success) {
            Log.d(TAG, "Leaf/SingBox started successfully")
            isRunning = true
            SingBoxVpnService.isRunning = true
        } else {
            throw Exception("Failed to start Leaf/SingBox service")
        }
    }
    
    private fun stopVPN() {
        try {
            isRunning = false
            SingBoxVpnService.isRunning = false
            
            // Stop Leaf/SingBox service
            LeafWrapper.stop()
            
            vpnInterface?.close()
            vpnInterface = null
            stopSelf()
            
            Log.d(TAG, "VPN Stopped")
        } catch (e: Exception) {
            Log.e(TAG, "Error stopping VPN", e)
        }
    }
    
    override fun onDestroy() {
        stopVPN()
        super.onDestroy()
    }
}
