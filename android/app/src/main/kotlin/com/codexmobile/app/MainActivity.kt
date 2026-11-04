package com.codexmobile.app

import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.codexmobile.app.terminal.PtyPlugin

/// Codex Mobile Pro 主 Activity
///
/// 注册 Native 插件（PTY / 日志导出），处理 Flutter ↔ Native 通信。
class MainActivity : FlutterActivity() {

    private val ptyPlugin by lazy { PtyPlugin(this) }
    private val logExportPlugin by lazy { LogExportPlugin(this) }
    private val updateInstallerPlugin by lazy { UpdateInstallerPlugin(this) }

    private var launchChannel: MethodChannel? = null
    private var pendingSelfTest = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        pendingSelfTest = intent?.getBooleanExtra("codex_self_test", false) ?: false

        // 注册 PTY 终端插件（forkpty / execve）
        ptyPlugin.registerWith(flutterEngine)

        // 注册日志导出插件（MediaStore → Download）
        logExportPlugin.registerWith(flutterEngine)

        // 注册更新安装插件（FileProvider → 系统包安装器）
        updateInstallerPlugin.registerWith(flutterEngine)

        // 暴露本次启动 Intent 的只读参数。真机自测由 Termux 通过
        // `am start --ez codex_self_test true` 触发，不影响普通启动。
        launchChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.codexmobile.app/launch",
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "consumeSelfTest" -> {
                        val requested = synchronized(this) {
                            val value = pendingSelfTest
                            pendingSelfTest = false
                            intent?.removeExtra("codex_self_test")
                            value
                        }
                        result.success(requested)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (intent.getBooleanExtra("codex_self_test", false)) {
            synchronized(this) {
                pendingSelfTest = true
            }
            // App 已在前台时不会触发 onCreate，主动通知 Dart 侧消费本次请求。
            launchChannel?.invokeMethod("selfTestRequested", null)
        }
    }

    override fun onDestroy() {
        // 清理 PTY 会话
        ptyPlugin.disposeAll()
        launchChannel?.setMethodCallHandler(null)
        launchChannel = null
        super.onDestroy()
    }
}
