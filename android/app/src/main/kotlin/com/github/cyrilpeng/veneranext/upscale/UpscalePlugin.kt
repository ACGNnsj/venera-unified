package com.github.cyrilpeng.veneranext.upscale

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.opencv.android.OpenCVLoader
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

/**
 * MethodChannel 桥接：Dart 侧通过 'venera/upscale' 方法调用原生超分核心。
 * 单次调用完成：输入图片字节 -> 预处理 -> ONNX 推理 -> 后处理 -> 返回 PNG 字节。
 *
 * 移植自 Venera-SSR（com.github.kiastr.venera_ssr.colorize.ColorizePlugin），
 * 删除上色/外部模型导入路径（copyUri），方法改名 upscale，增加 close() 供
 * MainActivity 在 cleanUp/onDestroy 时确定性释放。
 */
class UpscalePlugin : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "venera/upscale"

        fun registerWith(context: Context, messenger: BinaryMessenger): UpscalePlugin {
            val plugin = UpscalePlugin(context, messenger)
            plugin.channel.setMethodCallHandler(plugin)
            return plugin
        }
    }

    private val context: Context
    private val channel: MethodChannel
    private val engine = UpscaleEngine()
    private val executor = Executors.newSingleThreadExecutor()

    constructor(context: Context, messenger: BinaryMessenger) {
        this.context = context
        this.channel = MethodChannel(messenger, CHANNEL)
    }

    @Volatile
    private var openCvReady = false

    /** OpenCV 4.x Maven AAR 通过 OpenCVLoader.initDebug() 加载内置 .so（debug/release 均可用）。 */
    private fun ensureOpenCv() {
        if (!openCvReady) {
            synchronized(this) {
                if (!openCvReady) {
                    openCvReady = OpenCVLoader.initDebug()
                }
            }
        }
    }

    /**
     * 确定性释放：解绑 channel + 停后台线程 + 关 ONNX 会话。
     * OrtEnvironment 为进程级单例，不在此关闭（与上游行为一致）。
     */
    fun close() {
        try {
            channel.setMethodCallHandler(null)
        } catch (_: Exception) {
        }
        executor.shutdown()
        try {
            engine.close()
        } catch (_: Exception) {
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "resetSession") {
            // 丢弃已缓存的 ONNX 会话，下次推理按当前模型路径重新加载。
            // 切换/导入/删除模型后必须调用，否则 ModelManager 按路径缓存会沿用旧会话。
            engine.resetSession()
            result.success(null)
            return
        }
        if (call.method != "upscale") {
            result.notImplemented()
            return
        }
        val imageBytes = call.argument<ByteArray>("imageBytes")
        val modelPath = call.argument<String>("modelPath")
        val useNnapi = call.argument<Boolean>("useNnapi") ?: false
        val intensity = call.argument<Double>("intensity")?.toFloat() ?: 1.0f

        if (imageBytes == null || modelPath == null) {
            result.error("BAD_ARGS", "imageBytes / modelPath 不能为空", null)
            return
        }

        // 推理在后台线程执行，避免阻塞 UI（MethodChannel 结果回主线程派发）
        executor.execute {
            try {
                ensureOpenCv()
                if (!openCvReady) {
                    result.error("OPENCV_FAILED", "OpenCV native libs failed to load", null)
                    return@execute
                }
                val inputBitmap = BitmapFactory.decodeByteArray(imageBytes, 0, imageBytes.size)
                    ?: run {
                        result.error("DECODE_FAILED", "无法解码输入图片", null)
                        return@execute
                    }
                val outBitmap = engine.upscale(inputBitmap, modelPath, useNnapi, intensity)
                val baos = ByteArrayOutputStream()
                outBitmap.compress(Bitmap.CompressFormat.PNG, 100, baos)
                inputBitmap.recycle()
                outBitmap.recycle()
                result.success(baos.toByteArray())
            } catch (e: Throwable) {
                // 捕获 Throwable（含 Error/OOM），以 PlatformException 返回而非让进程崩溃
                result.error("UPSCALE_FAILED", e.message ?: "unknown error", null)
            }
        }
    }
}
