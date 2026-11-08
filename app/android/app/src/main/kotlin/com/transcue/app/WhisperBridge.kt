package com.transcue.app

import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteOrder
import java.util.concurrent.Executors

/// 기기 안 음성 인식 (데스크톱의 ffmpeg + whisper-cli 대신).
/// 영상의 한 구간 소리를 Android 디코더로 16kHz 모노로 바꾸고 whisper.cpp(JNI)로 받아 적는다.
class WhisperBridge(messenger: BinaryMessenger) {
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    init {
        System.loadLibrary("transcue_whisper")
        MethodChannel(messenger, "transcue/whisper").setMethodCallHandler { call, result ->
            if (call.method != "transcribe") return@setMethodCallHandler result.notImplemented()
            val path = call.argument<String>("path")!!
            val startMs = (call.argument<Number>("startMs")!!).toLong()
            val lengthMs = (call.argument<Number>("lengthMs")!!).toLong()
            val model = call.argument<String>("model")!!
            val vad = call.argument<String>("vad")
            val lang = call.argument<String>("lang") ?: "auto"
            val threads = call.argument<Int>("threads") ?: bigCores
            worker.execute {
                try {
                    val t0 = System.currentTimeMillis()
                    val pcm = decodeAudio(path, startMs, lengthMs)
                    val t1 = System.currentTimeMillis()
                    // 소리가 거의 없으면(영상 끝) 인식하지 않는다
                    val bytes = if (pcm.size < SAMPLE_RATE) null
                    else nativeTranscribe(model, vad, lang, threads, pcm)
                    val t2 = System.currentTimeMillis()
                    val text = bytes?.toString(Charsets.UTF_8)
                    main.post {
                        result.success(
                            mapOf(
                                "audioMs" to pcm.size * 1000L / SAMPLE_RATE,
                                "text" to text,
                                "decodeMs" to (t1 - t0),
                                "whisperMs" to (t2 - t1),
                            ),
                        )
                    }
                } catch (e: Throwable) {
                    main.post { result.error("stt", e.toString(), null) }
                }
            }
        }
    }

    private external fun nativeTranscribe(
        model: String, vad: String?, lang: String, threads: Int, pcm: FloatArray,
    ): ByteArray?

    companion object {
        const val SAMPLE_RATE = 16000

        /// 빠른 코어 수. 느린 코어까지 쓰면 연산마다 느린 코어를 기다려 전체가 느려진다
        /// (갤럭시 탭 S9: 3.36GHz×1 + 2.8GHz×4 + 2.0GHz×3 → 5)
        val bigCores: Int by lazy {
            val freqs = (0 until Runtime.getRuntime().availableProcessors()).mapNotNull {
                runCatching {
                    java.io.File("/sys/devices/system/cpu/cpu$it/cpufreq/cpuinfo_max_freq")
                        .readText().trim().toLong()
                }.getOrNull()
            }
            if (freqs.isEmpty()) 4
            else freqs.count { it > freqs.min() }.takeIf { it >= 2 } ?: freqs.size
        }

        /// [startMs, startMs+lengthMs] 구간의 소리 → 16kHz 모노 float
        fun decodeAudio(path: String, startMs: Long, lengthMs: Long): FloatArray {
            val ex = MediaExtractor()
            ex.setDataSource(path)
            var track = -1
            for (i in 0 until ex.trackCount) {
                if (ex.getTrackFormat(i).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true) {
                    track = i
                    break
                }
            }
            if (track < 0) {
                ex.release()
                throw IllegalStateException("소리 트랙이 없습니다")
            }
            val fmt = ex.getTrackFormat(track)
            ex.selectTrack(track)
            val startUs = startMs * 1000
            val endUs = (startMs + lengthMs) * 1000
            ex.seekTo(startUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)

            val codec = MediaCodec.createDecoderByType(fmt.getString(MediaFormat.KEY_MIME)!!)
            codec.configure(fmt, null, null, 0)
            codec.start()
            var rate = fmt.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            var channels = fmt.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            var float = false
            var mono = FloatArray(((lengthMs / 1000 + 2) * rate).toInt().coerceAtLeast(rate))
            var n = 0
            val info = MediaCodec.BufferInfo()
            var inputDone = false
            var done = false
            try {
                while (!done) {
                    if (!inputDone) {
                        val i = codec.dequeueInputBuffer(10_000)
                        if (i >= 0) {
                            val buf = codec.getInputBuffer(i)!!
                            val size = ex.readSampleData(buf, 0)
                            if (size < 0 || ex.sampleTime > endUs + 500_000) {
                                codec.queueInputBuffer(i, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                                inputDone = true
                            } else {
                                codec.queueInputBuffer(i, 0, size, ex.sampleTime, 0)
                                ex.advance()
                            }
                        }
                    }
                    val o = codec.dequeueOutputBuffer(info, 10_000)
                    when {
                        o == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                            val f = codec.outputFormat
                            rate = f.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                            channels = f.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                            float = f.containsKey(MediaFormat.KEY_PCM_ENCODING) &&
                                f.getInteger(MediaFormat.KEY_PCM_ENCODING) == AudioFormat.ENCODING_PCM_FLOAT
                        }
                        o >= 0 -> {
                            val buf = codec.getOutputBuffer(o)!!.order(ByteOrder.LITTLE_ENDIAN)
                            buf.position(info.offset)
                            val bps = if (float) 4 else 2
                            val frames = info.size / (bps * channels)
                            for (f in 0 until frames) {
                                val t = info.presentationTimeUs + f * 1_000_000L / rate
                                var sum = 0f
                                for (c in 0 until channels) {
                                    sum += if (float) buf.float else buf.short / 32768f
                                }
                                if (t < startUs) continue
                                if (t >= endUs) { done = true; break }
                                if (n == mono.size) mono = mono.copyOf(mono.size * 2)
                                mono[n++] = sum / channels
                            }
                            codec.releaseOutputBuffer(o, false)
                            if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) done = true
                        }
                    }
                }
            } finally {
                codec.stop()
                codec.release()
                ex.release()
            }
            return resample(mono, n, rate)
        }

        /// 선형 보간으로 16kHz로
        private fun resample(src: FloatArray, n: Int, rate: Int): FloatArray {
            if (rate == SAMPLE_RATE) return src.copyOf(n)
            val outN = (n.toLong() * SAMPLE_RATE / rate).toInt()
            val out = FloatArray(outN)
            val step = rate.toDouble() / SAMPLE_RATE
            for (i in 0 until outN) {
                val x = i * step
                val j = x.toInt()
                val frac = (x - j).toFloat()
                val a = src[j.coerceAtMost(n - 1)]
                val b = src[(j + 1).coerceAtMost(n - 1)]
                out[i] = a + (b - a) * frac
            }
            return out
        }
    }
}
