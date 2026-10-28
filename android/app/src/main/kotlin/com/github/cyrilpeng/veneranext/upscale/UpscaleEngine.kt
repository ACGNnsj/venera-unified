package com.github.cyrilpeng.veneranext.upscale

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import android.graphics.Bitmap
import org.opencv.core.Core
import org.opencv.core.CvType
import org.opencv.core.Mat
import org.opencv.core.MatOfDouble
import org.opencv.core.Rect
import org.opencv.core.Scalar
import org.opencv.core.Size
import org.opencv.imgproc.Imgproc
import java.util.Collections
import kotlin.math.roundToLong

/**
 * 超分计算核心。函数严格对齐参考实现：
 *  - ESRGAN   输入值域 0–1（/255），输出完整 RGB [1,3,scale·H,scale·W]；scale 由模型实际维度推导（见 getModelInfo）
 *  - ACNet    官方 Anime4K v4：1 通道 Y 亮度 [1,1,H,W] -> [1,1,2H,2W]，走 YCrCb 管线（见 upscaleAcnet）
 *             两者均模型无关（按输入通道数自动路由），换权重无需改原生
 *  - OpenCV float-LAB 真实范围 L∈[0,100]、a,b∈[−128,127]，必须用 OpenCV 转换
 *
 * 移植自 Venera-SSR（com.github.kiastr.venera_ssr.colorize.ColorizeEngine），
 * 删除上色路径（deoldify/ddcolor），仅保留超分（esrgan/acnet/modelInfo）。
 * 经真机模型端到端验证。
 */
class UpscaleEngine {

    companion object {
        // NNAPI 输出与 CPU 参考逐通道 MAE 阈值（[0,1] 空间）；超过即判定偏色，整图回退 CPU。
        // NNAPI 在部分设备上仅做 fp16 近似，正常数值误差远小于此；真偏色（通道错位/染色）通常在 0.1+。
        private const val NNAPI_COLOR_TOL = 0.04
        // 整图通道均值偏色阈值（uint8 空间 [0,255]）。仅 NNAPI 路径、全图推理完成后做一次：
        // 真偏色表现为 R 通道独高、G≈B，R-G 均值远超正常图（正常动漫各色平均后 R≈G≈B，典型 < 20）；
        // 实测染红设备 R-G 均值常 > 60，留足余量取 30。首 tile 的 MAE 检查会被顶部黑边蒙混
        // （NNAPI 对全黑输入也输出近乎全黑，MAE≈0），故以全图均值作兜底。
        private const val NNAPI_COLOR_TOL_RGB = 30.0
    }

    private val env: OrtEnvironment = OrtEnvironment.getEnvironment()
    private val modelManager = ModelManager(env)

    /**
     * 单次处理：输入已解码的 Bitmap，返回处理后的 Bitmap。
     * 不负责输入 Bitmap 的回收（由调用方持有），仅回收内部 Mat 与输出 Bitmap 之外的中间对象。
     */
    fun upscale(
        inputBitmap: Bitmap,
        modelPath: String,
        useNnapi: Boolean,
        intensity: Float
    ): Bitmap {
        // Utils.bitmapToMat 要求 ARGB_8888；非该配置会产出异常/空 Mat（曾导致 resize 空源崩溃）
        val (working, needsRecycle) = if (inputBitmap.config == Bitmap.Config.ARGB_8888) {
            Pair(inputBitmap, false)
        } else {
            Pair(inputBitmap.copy(Bitmap.Config.ARGB_8888, false), true)
        }
        if (working.width <= 0 || working.height <= 0) {
            if (needsRecycle) working.recycle()
            throw IllegalArgumentException("图片尺寸无效: ${working.width}x${working.height}")
        }
        val session = modelManager.getSession(modelPath, useNnapi)
        // 超分管线按模型输入通道数自动路由（3 = Real-ESRGAN RGB，1 = ACNet Y 亮度），
        // 无需按模型类型分发。
        val out = upscaleEsrgan(working, session, modelPath, useNnapi, intensity)
        if (needsRecycle) working.recycle()
        return out
    }

    // ----------------------------------------------------------------
    // ESRGAN / ACNet：输入 0–1，放大倍数由模型实际维度推导（见 getModelInfo）。
    //  - Real-ESRGAN：3 通道 RGB [1,3,H,W] -> [1,3,scale·H,scale·W]，全 RGB 管线；
    //  - 官方 Anime4K v4 ACNet：1 通道 Y 亮度 [1,1,H,W] -> [1,1,2H,2W]，走 upscaleAcnet
    //    （RGB -> YCrCb，Y 超分 + CbCr 双线性 -> 合并）。按输入通道数自动路由。
    // 对应 realesrgan 官方推理（img/255 -> RGB -> NCHW -> 推理 -> NCHW -> *255）
    //  - 不归一化到 ImageNet 均值（animevideov3 仅 /255）
    //  - intensity 围绕中性灰 0.5 做对比缩放（默认 1.0 = 不变）
    //
    // 固定尺寸分块策略（NNAPI 友好）：
    //  - 所有 tile（含边界残块）一律 padding 到恒定 TILE_IN×TILE_IN 再送入模型。
    //    ONNX Runtime 的 NNAPI EP 在模型含动态维度时按首次实际形状编译计算图；
    //    形状每变一次就重编译一次，是此前"大图极慢"的主因。输入形状恒定后
    //    整个会话只编译一次，后续 tile 直接复用，可全程走 GPU/NPU。
    //  - ART 堆峰值恒定 = 3*(4*TILE_IN)^2*4 字节 ≈ 28MB（与原图尺寸无关），
    //    彻底消除此前按图尺寸增长导致的 OOM。
    //  - 核心区在 tile 内恒定从 (PAD,PAD) 起，输出按 PAD*scale 中心裁剪，消除接缝。
    //  - NNAPI 输出健全性自检：首个 tile 若"输入非黑、输出全黑"，判定后端异常，
    //    自动整图切 CPU 重跑（CPU EP 对任意形状稳定正确）。
    // ----------------------------------------------------------------
    private fun upscaleEsrgan(
        inputBitmap: Bitmap,
        session: OrtSession,
        modelPath: String,
        useNnapi: Boolean,
        intensity: Float
    ): Bitmap {
        // 先探测模型输入通道数：Real-ESRGAN 为 3(RGB)，官方 Anime4K v4 ACNet 为 1(Y 亮度)。
        // 按通道路由到对应管线，模型无关——换权重无需改原生。
        val cpuSession = modelManager.getSession(modelPath, false)
        val info = getModelInfo(modelPath, cpuSession)
        if (info.channels == 1) {
            return upscaleAcnet(
                inputBitmap, session, modelPath, useNnapi, intensity, info.scale
            )
        }

        val bgr = ImageUtils.bitmapToBgrMat(inputBitmap) // (H,W,3) BGR uint8
        val h = bgr.height()
        val w = bgr.width()

        // BGR -> RGB（模型以 RGB 训练）-> float32 [0,1]（animevideov3 仅 /255）
        val rgb = Mat()
        Imgproc.cvtColor(bgr, rgb, Imgproc.COLOR_BGR2RGB)
        val rgbF = Mat()
        rgb.convertTo(rgbF, CvType.CV_32F, 1.0 / 255.0)
        bgr.release()
        rgb.release()

        try {
            // 放大倍数从模型实际输入/输出维度推导（探测一次并缓存），不再硬编码——
            // 换 2x/3x/4x 权重时自动适配，无需改代码。用 CPU 会话探测，与 NNAPI 是否偏色无关。
            val scale = info.scale
            if (!useNnapi) {
                // CPU：输出恒正确，无需自检
                val out = upscaleEsrganFixedTile(
                    rgbF, h, w, session, intensity, scale, cpuRef = null, channels = 3
                )!!
                return rgbU8ToBitmap(out)
            }
            // NNAPI：首 tile 与 CPU 参考对比，拦截后端返回的错误颜色（典型如整体偏红）。
            // 旧逻辑只检测"全黑"，漏掉了"偏色但仍非黑"的损坏——某些设备的 NNAPI
            // 会把 Real-ESRGAN 输出染红而非归零，表现就是超分后发红。
            val out = upscaleEsrganFixedTile(
                rgbF, h, w, session, intensity, scale, cpuRef = cpuSession, channels = 3
            )
            if (out != null) return rgbU8ToBitmap(out)

            // NNAPI 不可信 -> 整图切 CPU 重跑
            val outCpu = upscaleEsrganFixedTile(
                rgbF, h, w, cpuSession, intensity, scale, cpuRef = null, channels = 3
            )!!
            return rgbU8ToBitmap(outCpu)
        } finally {
            rgbF.release()
        }
    }

    /** uint8 RGB [H,W,3] -> Bitmap（RGB -> BGR，bgrMatToBitmap 内部再做 BGR2RGBA） */
    private fun rgbU8ToBitmap(outRgbU8: Mat): Bitmap {
        val outBgr = Mat()
        Imgproc.cvtColor(outRgbU8, outBgr, Imgproc.COLOR_RGB2BGR)
        outRgbU8.release()
        val bmp = ImageUtils.bgrMatToBitmap(outBgr)
        outBgr.release()
        return bmp
    }

    /**
     * 官方 Anime4K v4 ACNet 管线：模型只吃 1 通道 Y（亮度），色度通道双线性放大。
     * RGB -> YCrCb -> Y 用 ACNet 超分 + Cr/Cb 双线性 2x -> 合并回 YCrCb -> BGR。
     * 与 Anime4KCPP 官方 Android 集成一致（ACNet 即为此设计的 luma 超分器）。
     */
    private fun upscaleAcnet(
        inputBitmap: Bitmap,
        session: OrtSession,
        modelPath: String,
        useNnapi: Boolean,
        intensity: Float,
        scale: Int
    ): Bitmap {
        val bgr = ImageUtils.bitmapToBgrMat(inputBitmap)
        val h = bgr.height()
        val w = bgr.width()

        val ycrcb = Mat()
        Imgproc.cvtColor(bgr, ycrcb, Imgproc.COLOR_BGR2YCrCb)
        val planes = ArrayList<Mat>(3)
        Core.split(ycrcb, planes) // [Y, Cr, Cb]，Y 为亮度 uint8
        bgr.release()
        ycrcb.release()
        val y = planes[0]
        val cr = planes[1]
        val cb = planes[2]

        // Y -> float32 [0,1]
        val yF = Mat()
        y.convertTo(yF, CvType.CV_32F, 1.0 / 255.0)
        y.release()

        try {
            val cpuSession = modelManager.getSession(modelPath, false)
            val outY = if (!useNnapi) {
                upscaleEsrganFixedTile(
                    yF, h, w, session, intensity, scale, cpuRef = null, channels = 1
                )!!
            } else {
                upscaleEsrganFixedTile(
                    yF, h, w, session, intensity, scale, cpuRef = cpuSession, channels = 1
                ) ?: upscaleEsrganFixedTile(
                    yF, h, w, cpuSession, intensity, scale, cpuRef = null, channels = 1
                )!!
            }

            // 色度双线性放大（保持 uint8，与 Y 输出合并）
            val outW = w * scale
            val outH = h * scale
            val size = Size(outW.toDouble(), outH.toDouble())
            val crUp = Mat()
            Imgproc.resize(cr, crUp, size, 0.0, 0.0, Imgproc.INTER_LINEAR)
            val cbUp = Mat()
            Imgproc.resize(cb, cbUp, size, 0.0, 0.0, Imgproc.INTER_LINEAR)
            cr.release()
            cb.release()

            // 合并 [Y_up, Cr_up, Cb_up] -> YCrCb -> BGR
            val outYcrcb = Mat()
            Core.merge(listOf(outY, crUp, cbUp), outYcrcb)
            val outBgr = Mat()
            Imgproc.cvtColor(outYcrcb, outBgr, Imgproc.COLOR_YCrCb2BGR)
            outYcrcb.release()
            val bmp = ImageUtils.bgrMatToBitmap(outBgr)
            outBgr.release()
            outY.release()
            crUp.release()
            cbUp.release()
            return bmp
        } finally {
            yF.release()
        }
    }

    /**
     * 固定尺寸分块推理（模型无关，按 channels 区分 3 通道 RGB 与 1 通道 Y）。
     * 返回 uint8 输出 Mat（3 通道 RGB 或 1 通道 Y），由调用方做颜色空间转换。
     * 返回 null 表示 NNAPI 首 tile 自检未过（全黑或偏色，后端不可信），由调用方回退 CPU。
     * cpuRef 非空时开启自检；为 null 时（CPU 路径或回退重跑）不做自检。
     */
    private fun upscaleEsrganFixedTile(
        inputF: Mat, h: Int, w: Int,
        session: OrtSession, intensity: Float, scale: Int, cpuRef: OrtSession?,
        channels: Int
    ): Mat? {
        val outH = h * scale
        val outW = w * scale

        // 固定输入边长。384 兼顾单 tile 计算量与 ART 堆峰值（输出 1536² ≈ 28MB）
        val tileIn = 384
        val pad = 16                    // 每边重叠感受野，裁剪后消除接缝
        val core = tileIn - 2 * pad     // 每个 tile 实际贡献的有效边长 = 352

        // 全图 uint8 输出（native 内存，不占 ART 堆）
        val outU8 = Mat.zeros(outH, outW, CvType.CV_8UC(channels))
        val inputName = session.inputNames.iterator().next()
        var selfChecked = false

        var y = 0
        while (y < h) {
            val coreH = minOf(core, h - y)
            var x = 0
            while (x < w) {
                val coreW = minOf(core, w - x)

                // 源区域（核心区 + 四周 pad），clamp 到图像内
                val sx0 = maxOf(0, x - pad)
                val sy0 = maxOf(0, y - pad)
                val sx1 = minOf(w, x + coreW + pad)
                val sy1 = minOf(h, y + coreH + pad)

                // 补齐到恒定 tileIn×tileIn：越界侧与右/下不足部分用边缘复制填充
                // （BORDER_REPLICATE 对任意 border 大小安全；BORDER_REFLECT 在
                //  border >= 源边长时行为受限，小图会出问题）
                val padLeft = maxOf(0, pad - x)
                val padTop = maxOf(0, pad - y)
                val padRight = tileIn - padLeft - (sx1 - sx0)
                val padBottom = tileIn - padTop - (sy1 - sy0)

                val src = Mat(inputF, Rect(sx0, sy0, sx1 - sx0, sy1 - sy0))
                val tile = Mat()
                Core.copyMakeBorder(
                    src, tile, padTop, padBottom, padLeft, padRight, Core.BORDER_REPLICATE
                )
                src.release()

                // 推理：tile (tileIn,tileIn,channels) float[0,1] -> (1,channels,scale*tileIn,scale*tileIn) NCHW
                val buf = ImageUtils.hwcToNchwFloatBuffer(tile)
                val tensor = OnnxTensor.createTensor(
                    env, buf, longArrayOf(1L, channels.toLong(), tileIn.toLong(), tileIn.toLong())
                )
                val results = session.run(Collections.singletonMap(inputName, tensor))
                val outBuf = (results.get(0) as OnnxTensor).floatBuffer
                val outTile = ImageUtils.nchwToHwcMat(outBuf, channels, tileIn * scale, tileIn * scale)
                tensor.close()
                results.close()

                // 后端健全性自检（仅 NNAPI，cpuRef 即 CPU 参考会话）
                // 关键修正：旧逻辑只在“首个 tile”比对，而阅读器首 tile 常是黑边，
                // NNAPI 对全黑输入也输出近黑，MAE≈0，自检被蒙混通过。改为在“首个含内容
                // tile”上比对，且偏色比对排除近白像素（白底被 clip 在 1.0 看不出红偏，
                // 暗部/墨线最明显），彻底消除白底稀释导致的漏检。
                if (cpuRef != null && !selfChecked) {
                    // 该 tile 是否含内容（各通道标准差之和 > 阈值，排除纯黑/纯白边框）
                    val std = MatOfDouble(); val meanTmp = MatOfDouble()
                    Core.meanStdDev(tile, meanTmp, std)
                    var sumStd = 0.0
                    for (i in 0 until std.rows()) for (j in 0 until std.cols()) sumStd += std.get(i, j)[0]
                    val hasContent = sumStd > 0.02
                    if (hasContent) {
                        val inMean = Core.mean(tile).`val`
                        val outMean = Core.mean(outTile).`val`
                        var inSum = 0.0; var outSum = 0.0
                        for (i in 0 until channels) { inSum += inMean[i]; outSum += outMean[i] }
                        // 1) 全黑：输入非黑但输出全黑 => 后端异常（原自检逻辑保留）
                        if (inSum / channels > 0.05 && outSum / channels < 0.01) {
                            outTile.release()
                            tile.release()
                            outU8.release()
                            return null
                        }
                        // 2) 偏色/失真：与 CPU 参考 tile 在“非近白像素”上比对，逐通道 MAE 超阈值即
                        //    判定后端返回了错误颜色（典型如整体偏红）。NNAPI 在部分设备上仅做
                        //    fp16 近似，正常数值误差远小于阈值；真偏色 MAE 通常在 0.1+，
                        //    阈值取 0.04（≈10/255）留足余量。非近白像素排除后，白底稀释不再漏检。
                        try {
                            val refBuf = ImageUtils.hwcToNchwFloatBuffer(tile)
                            val refTensor = OnnxTensor.createTensor(
                                env, refBuf, longArrayOf(1L, channels.toLong(), tileIn.toLong(), tileIn.toLong())
                            )
                            val refRes = cpuRef.run(Collections.singletonMap(inputName, refTensor))
                            val refOut = (refRes.get(0) as OnnxTensor).floatBuffer
                            val refTile = ImageUtils.nchwToHwcMat(refOut, channels, tileIn * scale, tileIn * scale)
                            refTensor.close()
                            refRes.close()
                            val mae = maxChannelMaeOnContent(outTile, refTile, channels)
                            refTile.release()
                            if (mae > NNAPI_COLOR_TOL) {
                                outTile.release()
                                tile.release()
                                outU8.release()
                                return null
                            }
                        } catch (_: Exception) {
                            // 参考比对异常则不阻断 NNAPI（退化为仅“全黑”自检）
                        }
                        selfChecked = true
                    }
                }
                tile.release()

                // 核心区在 tile 内恒定从 (pad,pad) 起（已验证与 x/y 是否贴边无关）
                val cropRgb = Mat(
                    outTile,
                    Rect(pad * scale, pad * scale, coreW * scale, coreH * scale)
                )
                val cropCopy = Mat()
                cropRgb.copyTo(cropCopy)
                outTile.release()

                // intensity：围绕 0.5 做对比缩放，在 float 空间计算避免截断误差
                if (intensity != 1.0f) {
                    val half = Mat(cropCopy.size(), cropCopy.type(), Scalar(0.5))
                    val centered = Mat()
                    Core.subtract(cropCopy, half, centered)
                    Core.multiply(centered, Scalar(intensity.toDouble()), centered)
                    Core.add(centered, half, cropCopy)
                    centered.release()
                    half.release()
                }

                // *255 -> uint8（convertTo 的 alpha=255：cvRound + 饱和截断 = clip[0,255]）
                val cropU8 = Mat()
                cropCopy.convertTo(cropU8, CvType.CV_8U, 255.0)
                cropCopy.release()

                // 写入整图输出 ROI
                val roi = Mat(outU8, Rect(x * scale, y * scale, coreW * scale, coreH * scale))
                cropU8.copyTo(roi)
                cropU8.release()
                roi.release()

                x += coreW
            }
            y += coreH
        }

        // 整图偏色兜底（仅 NNAPI + 3 通道 RGB 路径）：在“非近白像素”上统计 R-G 均值，避免白底把
        // 整体偏色均值稀释到阈值以下而漏检。命中即整图作废，由调用方切 CPU 重跑。
        // 单通道 Y 无颜色信息，不适用该检查。
        if (cpuRef != null && channels == 3) {
            val bias = redShiftOnContent(outU8)
            if (bias > NNAPI_COLOR_TOL_RGB) {
                outU8.release()
                return null
            }
        }

        return outU8
    }

    fun close() {
        modelManager.close()
    }

    /**
     * 两个 float HWC Mat 的逐通道 mean absolute error，取各通道中的最大值。
     * 仅在“非近白像素”（max(R,G,B) < 0.9；单通道取 max < 0.9）上统计，
     * 去除白底对偏色均值的稀释：染红设备的红偏是加性偏移，白底被 clip 在 1.0 看不出，
     * 暗部/墨线最明显。用于 NNAPI 输出与 CPU 参考的偏色/失真比对。
     */
    private fun maxChannelMaeOnContent(a: Mat, b: Mat, channels: Int = 3): Double {
        if (channels == 1) {
            val mask = Mat()
            Core.compare(a, Scalar(0.9), mask, Core.CMP_LT) // 非近白像素
            val total = Core.countNonZero(mask)
            if (total == 0) { mask.release(); return 0.0 } // 整 tile 近白，无法判定，视为通过
            val d = Mat()
            Core.absdiff(a, b, d)
            val m = Core.mean(d, mask).`val`
            d.release(); mask.release()
            return m[0]
        }
        val ch = ArrayList<Mat>(3)
        Core.split(a, ch)
        val m1 = Mat(); val maxc = Mat()
        Core.max(ch[0], ch[1], m1); Core.max(m1, ch[2], maxc)
        ch.forEach { it.release() }; m1.release()
        val mask = Mat()
        Core.compare(maxc, Scalar(0.9), mask, Core.CMP_LT) // 非近白像素
        maxc.release()
        val total = Core.countNonZero(mask)
        if (total == 0) { mask.release(); return 0.0 } // 整 tile 近白，无法判定，视为通过
        val d = Mat()
        Core.absdiff(a, b, d)
        val m = Core.mean(d, mask).`val`
        d.release(); mask.release()
        return maxOf(m[0], m[1], m[2])
    }

    /**
     * 整图“红偏”度量：在“非近白像素”上统计 mean(R - G)（uint8 空间 [0,255]）。
     * 正常动漫各色平均后 R≈G≈B，偏色时 R 独高。排除白底以免稀释。
     */
    private fun redShiftOnContent(a: Mat): Double {
        val ch = ArrayList<Mat>(3)
        Core.split(a, ch)
        val m1 = Mat(); val maxc = Mat()
        Core.max(ch[0], ch[1], m1); Core.max(m1, ch[2], maxc)
        val mask = Mat()
        Core.compare(maxc, Scalar(230.0), mask, Core.CMP_LT) // 非近白像素（outRgbU8 为 uint8，阈值取 0.9*255）
        m1.release(); maxc.release()
        val rg = Mat()
        Core.subtract(ch[0], ch[1], rg)
        ch.forEach { it.release() }
        val total = Core.countNonZero(mask)
        val bias = if (total == 0) 0.0 else Core.mean(rg, mask).`val`[0]
        rg.release(); mask.release()
        return bias
    }

    /**
     * 模型信息：输入通道数（1 = Y 亮度/官方 ACNet，3 = RGB/Real-ESRGAN）+ 放大倍数。
     * 用一次极小的 dummy 前向（CPU 会话，与 NNAPI 是否偏色无关）测量输出/输入的空间比值，
     * 并按 modelPath 缓存。依次尝试 3 通道与 1 通道——Real-ESRGAN 吃 RGB，官方 ACNet 吃单通道 Y。
     *
     * 用输出 NCHW float buffer 的长度反推边长，避免依赖各 onnxruntime 版本输出 shape API 的差异。
     */
    private class ModelInfo(val channels: Int, val scale: Int)

    private val modelInfoCache = HashMap<String, ModelInfo>()

    private fun getModelInfo(modelPath: String, cpuSession: OrtSession): ModelInfo {
        synchronized(modelInfoCache) {
            modelInfoCache[modelPath]?.let { return it }
        }
        val probeIn = 64 // 正方形小图，输出必为 (probeIn*scale)²，避免动态维度干扰
        val inputName = cpuSession.inputNames.iterator().next()
        var found: ModelInfo? = null
        // 全零 dummy 即可：形状与具体数值无关。先试 3 通道（Real-ESRGAN），失败再试 1 通道（ACNet）。
        for (ch in intArrayOf(3, 1)) {
            try {
                val dummy = Mat.zeros(
                    probeIn, probeIn,
                    if (ch == 3) CvType.CV_32FC(3) else CvType.CV_32FC(1)
                )
                val buf = ImageUtils.hwcToNchwFloatBuffer(dummy)
                dummy.release()
                val tensor = OnnxTensor.createTensor(
                    env, buf, longArrayOf(1L, ch.toLong(), probeIn.toLong(), probeIn.toLong())
                )
                val results = cpuSession.run(Collections.singletonMap(inputName, tensor))
                val outBuf = (results.get(0) as OnnxTensor).floatBuffer
                val total = outBuf.remaining().toLong() // 1*ch*outH*outW
                val px = total / ch
                val side = kotlin.math.sqrt(px.toDouble()).roundToLong() // 输入正方形 => 输出正方形
                tensor.close()
                results.close()
                val scale =
                    if (side > 0 && side % probeIn == 0L) (side / probeIn).toInt()
                    else if (ch == 1) 2 else 4
                found = ModelInfo(ch, scale)
                break
            } catch (_: Exception) {
                // 通道数不符（1ch 模型拒绝 3ch 输入等），尝试下一个
            }
        }
        val info = found ?: ModelInfo(3, 1)
        synchronized(modelInfoCache) {
            modelInfoCache[modelPath] = info
        }
        return info
    }

    /// 丢弃已缓存的 ONNX 会话（仅关闭 session，不释放 env）。
    /// 模型切换/导入/删除后调用，使下次推理按当前路径重新加载。
    fun resetSession() {
        modelManager.close()
    }
}
