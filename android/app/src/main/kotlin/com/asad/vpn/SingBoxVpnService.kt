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
            .addAddress("10.0.0.2", 24)
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
        
        // Create V2Ray config for libv2ray
        // This format is specific to AndroidLibV2rayLite
        val v2rayConfig = JSONObject().apply {
            put("dns", JSONObject().apply {
                put("hosts", JSONObject().apply {
                    put("domain:googleapis.cn", "googleapis.com")
                })
                put("servers", JSONArray().apply {
                    put("1.1.1.1")
                    put("8.8.8.8")
                })
            })
            
            put("log", JSONObject().apply {
                put("loglevel", "warning")
            })
            
            put("routing", JSONObject().apply {
                put("domainStrategy", "IPIfNonMatch")
                put("rules", JSONArray().apply {
                    // Add basic routing rules
                    put(JSONObject().apply {
                        put("type", "field")
                        put("ip", JSONArray().apply {
                            put("geoip:private")
                        })
                        put("outboundTag", "direct")
                    })
                })
            })
            
            put("inbounds", JSONArray().apply {
                // Socks inbound for local apps
                put(JSONObject().apply {
                    put("tag", "socks")
                    put("port", 10808)
                    put("listen", "127.0.0.1")
                    put("protocol", "socks")
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
                // VLESS outbound
                put(JSONObject().apply {
                    put("tag", "proxy")
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
                                        put("level", 8)
                                        if (flow.isNotEmpty() && flow != "none") {
                                            put("flow", flow)
                                        }
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
                                put("multiMode", false)
                            })
                        }
                    })
                })
                
                // Direct outbound
                put(JSONObject().apply {
                    put("tag", "direct")
                    put("protocol", "freedom")
                    put("settings", JSONObject())
                })
                
                // Block outbound
                put(JSONObject().apply {
                    put("tag", "block")
                    put("protocol", "blackhole")
                    put("settings", JSONObject().apply {
                        put("response", JSONObject().apply {
                            put("type", "http")
                        })
                    })
                })
            })
        }
        
        val configJson = v2rayConfig.toString(2)
        Log.d(TAG, "V2Ray config generated, length: ${configJson.length}")
        
        // Start V2Ray using native library with VPN file descriptor
        val success = V2RayWrapper.startV2Ray(vpnFd, configJson)
        
        if (success) {
            Log.d(TAG, "V2Ray started successfully via native library")
            isRunning = true
            SingBoxVpnService.isRunning = true
        } else {
            throw Exception("Failed to start V2Ray via native library")
        }
    }
    
    private fun stopVPN() {
        try {
            isRunning = false
            SingBoxVpnService.isRunning = false
            
            // Stop V2Ray via native library
            V2RayWrapper.stopV2Ray()
            
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