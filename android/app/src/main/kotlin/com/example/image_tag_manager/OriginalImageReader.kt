package com.example.image_tag_manager

import android.content.Context
import android.net.Uri
import java.io.File
import java.util.UUID

/** One read-only original stream, staged privately so Flutter can decode GIFs too. */
class OriginalImageReader(private val context: Context) {
    private val directory = File(context.cacheDir, "original-viewer").apply { mkdirs() }
    private val active = mutableSetOf<String>()
    private val filename = Regex("[0-9a-f-]{36}\\.image")
    init {
        // This reader is created once per activity; discard leftovers from an older session.
        directory.listFiles()?.filter { it.isFile && filename.matches(it.name) }?.forEach { it.delete() }
    }

    @Synchronized fun open(uri: Uri): Map<String, String> {
        val token = "${UUID.randomUUID()}.image"
        val file = File(directory, token)
        try {
            context.contentResolver.openInputStream(uri)?.use { input ->
                file.outputStream().use { output ->
                    val buffer = ByteArray(64 * 1024)
                    var total = 0L
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        total += count
                        check(total <= 128L * 1024 * 1024) { "图片超过查看器 128 MiB 的单文件上限" }
                        output.write(buffer, 0, count)
                    }
                    check(total > 0) { "图片为空或已无法读取" }
                }
            } ?: error("无法读取原图，请检查照片权限或文件是否存在")
            active.add(token)
            return mapOf("token" to token, "path" to file.absolutePath)
        } catch (error: Exception) {
            file.delete()
            throw error
        }
    }

    @Synchronized fun close(token: String) {
        if (active.remove(token) && filename.matches(token)) File(directory, token).delete()
    }
}
