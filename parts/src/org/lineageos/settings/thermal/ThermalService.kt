/*
 * SPDX-FileCopyrightText: 2020 The LineageOS Project
 * SPDX-FileCopyrightText: 2025 Paranoid Android
 * SPDX-License-Identifier: Apache-2.0
 */

package org.lineageos.settings.thermal

import android.app.ActivityTaskManager
import android.app.KeyguardManager
import android.app.Service
import android.app.TaskStackListener
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.SharedPreferences
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.UserHandle
import androidx.preference.PreferenceManager
import org.lineageos.settings.utils.Logging

/** One foreground-app monitor for thermal profiles and opted-in game networking. */
class ThermalService : Service() {
    private lateinit var thermalUtils: ThermalUtils
    private lateinit var networkLatency: NetworkLatencyController
    private lateinit var preferences: SharedPreferences
    private val handler = Handler(Looper.getMainLooper())
    private var destroyed = false
    private var appliedProfile: String? = null
    private val refresh = Runnable { refreshState() }

    private val taskListener = object : TaskStackListener() {
        override fun onTaskStackChanged() = scheduleRefresh()
    }
    private val preferenceListener = SharedPreferences.OnSharedPreferenceChangeListener { _, _ ->
        appliedProfile = null
        scheduleRefresh()
    }
    private val intentReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) = scheduleRefresh()
    }

    private fun scheduleRefresh() {
        handler.post {
            if (!destroyed) {
                handler.removeCallbacks(refresh)
                refreshState()
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        thermalUtils = ThermalUtils.getInstance(this)
        networkLatency = NetworkLatencyController(this, handler)
        preferences = PreferenceManager.getDefaultSharedPreferences(this)
        preferences.registerOnSharedPreferenceChangeListener(preferenceListener)
        runCatching { ActivityTaskManager.getService().registerTaskStackListener(taskListener) }
            .onFailure { Logging.e(TAG, "Cannot monitor the foreground task", it) }
        registerReceiver(
            intentReceiver,
            IntentFilter().apply {
                addAction(Intent.ACTION_SCREEN_OFF)
                addAction(Intent.ACTION_SCREEN_ON)
                addAction(Intent.ACTION_USER_PRESENT)
                addAction(Intent.ACTION_USER_SWITCHED)
            },
            Context.RECEIVER_NOT_EXPORTED,
        )
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (!thermalUtils.enabled) {
            networkLatency.update(NetworkLatencyController.DISABLED)
            stopSelf()
            return START_NOT_STICKY
        }
        refreshState()
        return START_STICKY
    }

    private fun refreshState() {
        if (destroyed) return
        handler.removeCallbacks(refresh)
        val interactive = getSystemService(PowerManager::class.java).isInteractive &&
            !getSystemService(KeyguardManager::class.java).isKeyguardLocked
        val task = if (interactive && thermalUtils.enabled) {
            runCatching { ActivityTaskManager.getService().focusedRootTaskInfo }.getOrNull()
        } else null
        // Never apply this user's saved choices to an app in another Android user.
        if (task != null && task.userId != UserHandle.myUserId()) {
            networkLatency.update(NetworkLatencyController.DISABLED)
            return
        }
        val packageName = task?.topActivity?.packageName.orEmpty()
        val profileKey = if (thermalUtils.enabled) packageName else ""
        if (profileKey != appliedProfile) {
            if (profileKey.isEmpty()) thermalUtils.setIdleProfile()
            else thermalUtils.setThermalProfile(profileKey)
            appliedProfile = profileKey
        }

        var uid = NetworkLatencyController.DISABLED
        if (thermalUtils.enabled && packageName.isNotEmpty() &&
            thermalUtils.isNetworkLatencyEnabled(packageName) && thermalUtils.isGame(packageName)) {
            uid = runCatching { packageManager.getApplicationInfo(packageName, 0).uid }
                .getOrDefault(NetworkLatencyController.DISABLED)
        }
        networkLatency.update(uid)
        if (uid != NetworkLatencyController.DISABLED) {
            // Recheck the existing foreground source before renewing the driver's 15s lease.
            handler.postDelayed(refresh, LEASE_REFRESH_MS)
        }
    }

    override fun onDestroy() {
        destroyed = true
        handler.removeCallbacksAndMessages(null)
        networkLatency.close()
        preferences.unregisterOnSharedPreferenceChangeListener(preferenceListener)
        unregisterReceiver(intentReceiver)
        runCatching { ActivityTaskManager.getService().unregisterTaskStackListener(taskListener) }
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    companion object {
        private const val TAG = "ThermalService"
        private const val LEASE_REFRESH_MS = 5000L
    }
}
