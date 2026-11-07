package com.github.cyrilpeng.veneranext.upscale

import android.os.Build
import android.util.Log

/**
 * 探测本机是否存在可用的 NNAPI 运行时。
 *
 * 背景：NNAPI 在 Android 15（API 35）被标记废弃，Android 16 起 Google 从系统里
 * 移除了运行时。真机核实（SM-S9480 / Android 17）：/system/lib64/libneuralnetworks.so
 * 与 neuralnetworks 服务都不存在，但 ONNX Runtime 仍能建出「NNAPI 会话」，所有节点
 * 静默落回 CPU——既没有加速，还白跑一遍 CPU 参考推理。因此建会话前先探一次：
 * 探不到就直接走 CPU，不再请求 NNAPI。
 */
object NnapiSupport {

    private const val TAG = "UpscaleNnapi"

    /** Android 16（API 36）起系统不再提供 NNAPI 运行时，不必再尝试加载。 */
    private const val FIRST_SDK_WITHOUT_RUNTIME = 36

    @Volatile
    private var cached: Boolean? = null

    /** 本机是否可用 NNAPI；结果按进程缓存，避免每次建会话都加载动态库。 */
    fun isAvailable(): Boolean {
        cached?.let { return it }
        synchronized(this) {
            cached?.let { return it }
            val available = probe()
            cached = available
            Log.i(
                TAG,
                if (available) {
                    "NNAPI runtime available (sdk=" + Build.VERSION.SDK_INT + ")"
                } else {
                    "NNAPI runtime missing (sdk=" + Build.VERSION.SDK_INT + "); upscale uses CPU"
                }
            )
            return available
        }
    }

    private fun probe(): Boolean {
        if (Build.VERSION.SDK_INT >= FIRST_SDK_WITHOUT_RUNTIME) return false
        return try {
            // 与 NNAPI EP 内部一致：动态库能加载才算运行时真的在。
            System.loadLibrary("neuralnetworks")
            true
        } catch (e: Throwable) {
            false
        }
    }
}
