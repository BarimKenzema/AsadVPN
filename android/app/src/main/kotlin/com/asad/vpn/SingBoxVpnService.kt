package com.asad.vpn

import android.content.Intent
import android.net.ProxyInfo
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.util.Log
import io.nekohasekai.libbox.BoxService
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.PlatformInterface
import io.nekohasekai.libbox.SystemProxyStatus
import io.nekohasekai.libbox.TunOptions
import io.nekohasekai.libbox.Notification
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.GlobalScope
import kotlinx.coroutines.launch

class SingBoxVpnService : VpnService(), PlatformInterface {

    companion object {
        private const val TAG = "SingBoxVPN"
        const val EXTRA_CONFIG = "config"
        var isRunning = false
    }

    private var vpnInterface: ParcelFileDescriptor? = null
    private var boxService: BoxService? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val configJson = intent?.getStringExtra(EXTRA_CONFIG)
        if (configJson.isNullOrBlank()) {
            Log.e(TAG, "No config provided")
            stopSelf()
            return START_NOT_STICKY
        }

        GlobalScope.launch(Dispatchers.IO) {
            runCatching {
                Libbox.setMemoryLimit(true)
                val svc = Libbox.newService(configJson, this@SingBoxVpnService)
                svc.start()
                boxService = svc
                isRunning = true
                Log.d(TAG, "Sing-box started")
            }.onFailure {
                Log.e(TAG, "Failed to start sing-box: ${it.message}", it)
                stopSelf()
            }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        stopCore()
        super.onDestroy()
    }

    private fun stopCore() {
        isRunning = false
        GlobalScope.launch(Dispatchers.IO) {
            runCatching { boxService?.close() }
                .onFailure { Log.e(TAG, "Error closing sing-box", it) }
            boxService = null
            try { vpnInterface?.close() } catch (_: Throwable) {}
            vpnInterface = null
            stopSelf()
        }
    }

    override fun openTun(options: TunOptions): Int {
        if (prepare(this) != null) {
            Log.e(TAG, "VPN permission not granted")
            return -1
        }

        val builder = Builder().setSession("AsadVPN").setMtu(options.mtu)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) builder.setMetered(false)

        val inet4 = options.inet4Address
        while (inet4.hasNext()) {
            val a = inet4.next()
            builder.addAddress(a.address(), a.prefix())
        }
        val inet6 = options.inet6Address
        while (inet6.hasNext()) {
            val a = inet6.next()
            builder.addAddress(a.address(), a.prefix())
        }

        if (options.autoRoute) {
            builder.addDnsServer(options.dnsServerAddress.value)
            builder.addRoute("0.0.0.0", 0)
            builder.addRoute("::", 0)
        }

        if (options.isHTTPProxyEnabled && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            builder.setHttpProxy(
                ProxyInfo.buildDirectProxy(
                    options.httpProxyServer,
                    options.httpProxyServerPort,
                    emptyList()
                )
            )
        }

        val pfd = builder.establish() ?: error("Failed to establish VPN")
        vpnInterface = pfd
        Log.d(TAG, "TUN established fd=${pfd.fd}")
        return pfd.fd
    }

    override fun autoDetectInterfaceControl(fd: Int) { protect(fd) }
    override fun writeLog(message: String) { Log.d("SingBoxCore", message) }
    override fun sendNotification(notification: Notification) {
        Log.d(TAG, "Core notification: ${notification.title} - ${notification.body}")
    }
    override fun getSystemProxyStatus(): SystemProxyStatus {
        return SystemProxyStatus().also { it.available = false; it.enabled = false }
    }
    override fun setSystemProxyEnabled(isEnabled: Boolean) { /* no-op */ }
}