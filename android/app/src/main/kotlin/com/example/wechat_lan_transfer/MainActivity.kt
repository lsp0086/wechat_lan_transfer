package com.example.wechat_lan_transfer

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var nsdManager: NsdManager? = null
    private var nsdListener: NsdManager.RegistrationListener? = null
    private var multicastLock: WifiManager.MulticastLock? = null

    /// N1：mDNS 发布（Android NSD `_wlt._tcp`，端口为 TCP 文件端口）。
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "wechat_lan_transfer/mdns",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "register" -> {
                    val name = call.argument<String>("name") ?: ""
                    val port = call.argument<Int>("port") ?: 0
                    val deviceId = call.argument<String>("deviceId") ?: ""
                    val udpPort = call.argument<Int>("udpPort") ?: 0
                    registerNsd(name, port, deviceId, udpPort, result)
                }
                "unregister" -> {
                    unregisterNsdQuietly()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        // v2 组播发现（224.0.0.167:53317）：Android 默认过滤组播包，
        // 必须 MulticastLock 才能收到（CHANGE_WIFI_MULTICAST_STATE 权限已在清单声明）。
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "wechat_lan_transfer/multicast",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "acquire" -> {
                    try {
                        releaseMulticastLockQuietly()
                        val wifi =
                            applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                        multicastLock = wifi.createMulticastLock("wlt_ls_discovery").apply {
                            setReferenceCounted(false)
                            acquire()
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("acquire_failed", e.message, null)
                    }
                }
                "release" -> {
                    releaseMulticastLockQuietly()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        unregisterNsdQuietly()
        releaseMulticastLockQuietly()
        super.cleanUpFlutterEngine(flutterEngine)
    }

    private fun releaseMulticastLockQuietly() {
        val lock = multicastLock ?: return
        multicastLock = null
        try {
            if (lock.isHeld) lock.release()
        } catch (_: Exception) {
        }
    }

    private fun registerNsd(
        name: String,
        port: Int,
        deviceId: String,
        udpPort: Int,
        result: MethodChannel.Result,
    ) {
        if (name.isBlank() || port <= 0) {
            result.error("bad_args", "name/port required", null)
            return
        }
        try {
            if (nsdManager == null) {
                nsdManager = getSystemService(Context.NSD_SERVICE) as NsdManager
            }
            unregisterNsdQuietly()
            val listener = object : NsdManager.RegistrationListener {
                override fun onServiceRegistered(serviceInfo: NsdServiceInfo) {
                    // 名称冲突时系统自动加 (1)/(2) 后缀，日志记录实际注册名
                    Log.d(TAG, "N1 NSD 已注册: ${serviceInfo.serviceName}")
                }

                override fun onRegistrationFailed(
                    serviceInfo: NsdServiceInfo,
                    errorCode: Int,
                ) {
                    Log.w(TAG, "N1 NSD 注册失败: errorCode=$errorCode")
                }

                override fun onServiceUnregistered(serviceInfo: NsdServiceInfo) {}

                override fun onUnregistrationFailed(
                    serviceInfo: NsdServiceInfo,
                    errorCode: Int,
                ) {
                    Log.w(TAG, "N1 NSD 注销失败: errorCode=$errorCode")
                }
            }
            nsdListener = listener
            val info = NsdServiceInfo().apply {
                serviceName = name
                serviceType = "_wlt._tcp."
                setPort(port)
                // N1：TXT 携带身份与 UDP 端口，消费端按其定位（key=value DNS-SD 格式）
                if (deviceId.isNotBlank()) setAttribute("deviceId", deviceId)
                if (udpPort > 0) setAttribute("udpPort", udpPort.toString())
                setAttribute("name", name)
            }
            nsdManager?.registerService(info, NsdManager.PROTOCOL_DNS_SD, listener)
            // 注册为异步 best-effort，结果立即回传（回调仅记日志）
            result.success(name)
        } catch (e: Exception) {
            result.error("register_failed", e.message, null)
        }
    }

    private fun unregisterNsdQuietly() {
        val listener = nsdListener ?: return
        nsdListener = null
        try {
            nsdManager?.unregisterService(listener)
        } catch (_: Exception) {
        }
    }

    private companion object {
        const val TAG = "MainActivity"
    }
}
