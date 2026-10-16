/*
 * SPDX-FileCopyrightText: 2026 The LineageOS Project
 * SPDX-License-Identifier: Apache-2.0
 */
package org.lineageos.settings.thermal

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.WorkSource
import java.io.File
import java.io.IOException
import org.lineageos.settings.utils.Logging

/** All calls, including network callbacks, run on the service's main handler. */
class NetworkLatencyController(context: Context, handler: Handler) {
    private val connectivity = context.getSystemService(ConnectivityManager::class.java)
    private val wifi = context.getSystemService(WifiManager::class.java)
    private val cellularControl = File(CELLULAR_CONTROL)
    private var requestedUid = DISABLED
    private var cellularUid = DISABLED
    private var wifiUid = DISABLED
    private var wifiLock: WifiManager.WifiLock? = null
    private var network: Network? = null
    private var capabilities: NetworkCapabilities? = null
    private var registered = false
    private var closed = false
    private var cellularErrorReported = false

    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            this@NetworkLatencyController.network = network
            capabilities = null
            apply()
        }

        override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
            if (network != this@NetworkLatencyController.network) return
            capabilities = caps
            apply()
        }

        override fun onLost(network: Network) {
            if (network != this@NetworkLatencyController.network) return
            this@NetworkLatencyController.network = null
            capabilities = null
            apply()
        }
    }

    init {
        try {
            connectivity.registerDefaultNetworkCallback(callback, handler)
            registered = true
            network = connectivity.activeNetwork
            capabilities = network?.let { connectivity.getNetworkCapabilities(it) }
        } catch (e: RuntimeException) {
            Logging.e(TAG, "Cannot monitor the active network", e)
        }
    }

    /** Repeated updates renew the RMNET lease; no permanent driver setting is used. */
    fun update(uid: Int) {
        if (closed) return
        requestedUid = uid
        apply()
    }

    private fun apply() {
        if (closed) return
        val caps = capabilities
        val enabled = requestedUid >= MIN_APP_UID && caps != null &&
            caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
        setWifiUid(
            if (enabled && caps!!.hasTransport(NetworkCapabilities.TRANSPORT_WIFI))
                requestedUid else DISABLED
        )
        // A VPN replaces the game's socket owner on the RMNET path. Do not apply
        // a game policy to the VPN's unrelated traffic.
        setCellularUid(
            if (enabled && caps!!.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) &&
                caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN))
                requestedUid else DISABLED
        )
    }

    private fun setWifiUid(uid: Int) {
        if (uid == wifiUid && (uid == DISABLED || wifiLock?.isHeld == true)) return
        try {
            if (wifiLock?.isHeld == true) wifiLock?.release()
            wifiLock = null
            wifiUid = DISABLED
            if (uid == DISABLED) return
            val lock = wifi.createWifiLock(WifiManager.WIFI_MODE_FULL_LOW_LATENCY, TAG)
            lock.setReferenceCounted(false)
            // WifiLockManager checks the foreground state of this UID, not XiaomiParts.
            lock.setWorkSource(WorkSource(uid))
            lock.acquire()
            wifiLock = lock
            wifiUid = uid
        } catch (e: RuntimeException) {
            Logging.e(TAG, "Cannot change the game Wi-Fi latency lock", e)
        }
    }

    private fun setCellularUid(uid: Int) {
        if (uid == DISABLED && cellularUid == DISABLED) return
        try {
            val request = if (uid == DISABLED) "off $cellularUid" else uid.toString()
            cellularControl.writeText("$request\n")
            cellularUid = uid
            cellularErrorReported = false
        } catch (e: IOException) {
            reportCellularError(e)
        } catch (e: SecurityException) {
            reportCellularError(e)
        }
    }

    private fun reportCellularError(e: Exception) {
        if (!cellularErrorReported) {
            Logging.e(TAG, "Cannot update the RMNET game lease", e)
            cellularErrorReported = true
        }
        // A failed release expires in the driver within 15 seconds.
    }

    fun close() {
        if (closed) return
        requestedUid = DISABLED
        setWifiUid(DISABLED)
        setCellularUid(DISABLED)
        closed = true
        if (registered) {
            runCatching { connectivity.unregisterNetworkCallback(callback) }
                .onFailure { Logging.w(TAG, "Cannot unregister network callback", it) }
            registered = false
        }
    }

    companion object {
        const val DISABLED = -1
        private const val MIN_APP_UID = 10000
        private const val TAG = "GameNetworkLatency"
        private const val CELLULAR_CONTROL =
            "/sys/module/rmnet_core/parameters/game_low_latency_uid"
    }
}
