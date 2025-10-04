package com.asad.vpn

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugins.GeneratedPluginRegistrant

class MainActivity: FlutterActivity() {
    private var vpnPlugin: VpnPlugin? = null
    
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        // Register the VPN plugin
        vpnPlugin = VpnPlugin()
        flutterEngine.plugins.add(vpnPlugin)
        
        GeneratedPluginRegistrant.registerWith(flutterEngine)
    }
    
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        vpnPlugin?.handleActivityResult(requestCode, resultCode, data)
    }
}