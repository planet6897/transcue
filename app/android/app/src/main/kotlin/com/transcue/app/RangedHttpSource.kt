package com.transcue.app

import android.media.MediaDataSource
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL

/// 주소의 필요한 부분만 1MB 조각(Range) 요청으로 받아 MediaExtractor에 넘긴다.
///
/// MediaExtractor.setDataSource(url)은 한 번에 통째로 여는데, YouTube는 그런 요청을
/// 재생 속도 정도로만 보내 줘서 30초 소리를 읽는 데 20초가 걸렸다 (갤럭시 탭 S9, 2026-11).
/// 조각 요청은 빠르게 받아진다. 받은 조각은 몇 개만 기억해 둔다 (앞뒤로 오가며 읽으므로).
class RangedHttpSource(
    private val url: String,
    private val blockSize: Int = 1 shl 20,
    private val maxBlocks: Int = 8,
) : MediaDataSource() {
    private val blocks = object : LinkedHashMap<Long, ByteArray>(16, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<Long, ByteArray>?) =
            size > maxBlocks
    }
    private var total: Long = -1

    @Synchronized
    override fun getSize(): Long {
        if (total < 0) block(0)
        return total
    }

    @Synchronized
    override fun readAt(position: Long, buffer: ByteArray, offset: Int, size: Int): Int {
        if (size == 0) return 0
        if (total >= 0 && position >= total) return -1
        var pos = position
        var written = 0
        while (written < size) {
            val index = pos / blockSize
            val b = block(index)
            val within = (pos - index * blockSize).toInt()
            if (within >= b.size) break
            val n = minOf(size - written, b.size - within)
            System.arraycopy(b, within, buffer, offset + written, n)
            written += n
            pos += n
            if (total in 0..pos) break
        }
        return if (written == 0) -1 else written
    }

    private fun block(index: Long): ByteArray {
        blocks[index]?.let { return it }
        val from = index * blockSize
        if (total in 0..from) return ByteArray(0)
        var last: IOException? = null
        repeat(3) {
            try {
                val b = fetch(from, from + blockSize - 1)
                blocks[index] = b
                return b
            } catch (e: IOException) {
                last = e
            }
        }
        throw last!!
    }

    private fun fetch(from: Long, to: Long): ByteArray {
        val c = URL(url).openConnection() as HttpURLConnection
        try {
            c.connectTimeout = 15_000
            c.readTimeout = 30_000
            c.setRequestProperty("Range", "bytes=$from-$to")
            return when (c.responseCode) {
                206 -> {
                    c.getHeaderField("Content-Range")?.substringAfterLast('/')?.toLongOrNull()
                        ?.let { total = it }
                    c.inputStream.use { it.readBytes() }
                }
                416 -> {
                    if (total < 0) total = from
                    ByteArray(0)
                }
                else -> throw IOException("HTTP ${c.responseCode} for range $from-$to")
            }
        } finally {
            c.disconnect()
        }
    }

    override fun close() {
        synchronized(this) { blocks.clear() }
    }
}
