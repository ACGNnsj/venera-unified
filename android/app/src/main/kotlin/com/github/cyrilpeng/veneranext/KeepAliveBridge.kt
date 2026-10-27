package com.github.cyrilpeng.veneranext

import android.content.Context
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

class KeepAliveBridge(
    private val context: Context,
    messenger: BinaryMessenger,
    private val isNotificationGranted: () -> Boolean,
    private val requestNotificationPermission: ((Boolean) -> Unit) -> Unit,
) {
    private val channel = MethodChannel(messenger, "venera/background_keepalive")

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "update" -> {
                    val tag = call.argument<String>("tag")
                    if (tag.isNullOrEmpty()) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    try {
                        BackgroundKeepAliveService.update(
                            context, tag, call.argument<String>("status").orEmpty(),
                        )
                        result.success(true)
                    } catch (error: Exception) {
                        // Missing notification permission or background-start
                        // limits land here; Dart degrades silently.
                        Log.w("BackgroundKeepAlive", "update rejected: ${error.message}")
                        result.success(false)
                    }
                }
                "remove" -> {
                    val tag = call.argument<String>("tag")
                    if (!tag.isNullOrEmpty()) {
                        runCatching { BackgroundKeepAliveService.remove(context, tag) }
                            .onFailure { Log.w("BackgroundKeepAlive", "remove failed: ${it.message}") }
                    }
                    result.success(null)
                }
                "notificationGranted" -> result.success(isNotificationGranted())
                "requestNotification" -> {
                    if (isNotificationGranted()) {
                        result.success(true)
                    } else {
                        requestNotificationPermission { granted -> result.success(granted) }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    fun close() {
        channel.setMethodCallHandler(null)
    }
}
