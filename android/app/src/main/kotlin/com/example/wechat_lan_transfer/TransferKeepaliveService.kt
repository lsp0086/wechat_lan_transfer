package com.example.wechat_lan_transfer

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/// U3：传输前台 Service + wake lock。
/// 有传输任务时由 Dart 侧经 MethodChannel 拉起，任务空闲时停止；
/// 保活期间持有 partial wake lock + Wi-Fi lock，系统休眠不中断传输。
/// 2 小时上限兜底：异常路径未释锁时系统自动回收，防止常驻耗电。
class TransferKeepaliveService : Service() {

    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        goForeground("传输进行中")
        acquireLocks()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val text = intent?.getStringExtra(EXTRA_TEXT)
        if (!text.isNullOrBlank()) {
            updateNotification(text)
            // 重入 start 时补一次锁（异常 stop/start 竞态下兜底）
            acquireLocks()
        }
        return START_STICKY
    }

    override fun onDestroy() {
        releaseLocks()
        super.onDestroy()
    }

    private fun acquireLocks() {
        if (wakeLock?.isHeld != true) {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "wlt:transfer").apply {
                setReferenceCounted(false)
                acquire(WAKE_LOCK_TIMEOUT_MS)
            }
        }
        if (wifiLock?.isHeld != true) {
            val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            @Suppress("DEPRECATION")
            wifiLock = wm.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "wlt:wifi").apply {
                setReferenceCounted(false)
                acquire()
            }
        }
    }

    private fun releaseLocks() {
        try {
            if (wakeLock?.isHeld == true) wakeLock?.release()
        } catch (_: Exception) {
        }
        try {
            if (wifiLock?.isHeld == true) wifiLock?.release()
        } catch (_: Exception) {
        }
        wakeLock = null
        wifiLock = null
    }

    private fun goForeground(text: String) {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "局域网传输",
                NotificationManager.IMPORTANCE_LOW,
            )
            manager.createNotificationChannel(channel)
        }
        startForeground(NOTIFICATION_ID, buildNotification(text))
    }

    private fun updateNotification(text: String) {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(NOTIFICATION_ID, buildNotification(text))
    }

    private fun buildNotification(text: String): Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setContentTitle("局域网传输")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setOngoing(true)
            .build()
    }

    companion object {
        const val EXTRA_TEXT = "text"
        private const val CHANNEL_ID = "wlt_transfer"
        private const val NOTIFICATION_ID = 20260930
        private const val WAKE_LOCK_TIMEOUT_MS = 2 * 60 * 60 * 1000L

        /// Dart 侧入口：拉起前台 Service（已运行则更新文案）。
        fun start(context: Context, text: String) {
            val intent = Intent(context, TransferKeepaliveService::class.java)
            intent.putExtra(EXTRA_TEXT, text)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        /// Dart 侧入口：停止前台 Service（onDestroy 释锁）。
        /// stopService 后台直接可停，无需经 onStartCommand。
        fun stop(context: Context) {
            val intent = Intent(context, TransferKeepaliveService::class.java)
            context.stopService(intent)
        }
    }
}
