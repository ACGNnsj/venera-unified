package com.github.cyrilpeng.veneranext.upscale

import android.util.Log

/**
 * 探测本机是否存在可用的 NNAPI 运行时。
 *
 * 背景：NNAPI 在 Android 15（API 35）被标记废弃，较新的系统已把运行时从
 * ROM 里移除。真机核实（SM-S9480 / Android 17）：/system/lib64/libneuralnetworks.so
 * 与 neuralnetworks 服务都不存在，但 ONNX Runtime 仍能建出「NNAPI 会话」，所有节点
 * 静默落回 CPU——既没有加速，还白跑一遍 CPU 参考推理。因此建会话前先探一次：
 * 运行时加载不到就直接走 CPU，不再请求 NNAPI。
 *
 * 这里只按「动态库能否加载」判断，不写死版本号：不同 OEM 的取舍不一致，
 * 库还在就照常尝试（数值正确性仍由 CPU 参考比对兜底）。
 */
object NnapiSupport {

    private const val TAG = "UpscaleNnapi"

    @Volatile
    private var cached: Boolean? = null

    /** 本机是否可用 NNAPI；结果按进程缓存，避免每次建会话都加载动态库。 */
    fun isAvailable(): Boolean {
        cached?.let { return it }
        synchronized(this) {
            cached?.let { return it }
            var detail: String? = null
            val available = try {
                // 与 NNAPI EP 内部一致：动态库能加载才算运行时真的在。
                System.loadLibrary("neuralnetworks")
                true
            } catch (e: Throwable) {
                detail = e.javaClass.simpleName
                false
            }
            cached = available
            Log.i(
                TAG,
                if (available) {
                    "NNAPI runtime available"
                } else if (detail != null) {
                    "NNAPI runtime missing (" + detail + "); upscale uses CPU"
                } else {
                    "NNAPI runtime unavailable; upscale uses CPU"
                }
            )
            return available
        }
    }
}
