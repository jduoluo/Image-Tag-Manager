package com.example.image_tag_manager

import android.system.Os
import android.system.OsConstants
import java.io.File

/** A directory's identity, rather than its MediaStore spelling, is the album key. */
internal class MediaAlbumCatalog {
    data class Folder(val id: String, val name: String, val volume: String) {
        fun map(): Map<String, Any> = mapOf("id" to id, "name" to name, "volume" to volume)
    }
    data class Album(val id: String, val name: String, val volume: String, val folders: List<Folder>)
    private val cached = mutableMapOf<String, Album>()
    private val folderIds = mutableMapOf<String, String>()

    fun album(relative: String?, data: String?, volume: String?): Album {
        val label = relative?.trim()?.takeIf { it.isNotEmpty() } ?: "未标明位置"
        val actualVolume = volume?.takeIf { it.isNotBlank() } ?: "legacy"
        val parent = data?.let { File(it).parentFile }
        val parentKey = "$actualVolume|${parent?.path}|$label"
        return cached.getOrPut(parentKey) {
            val depth = label.split('/').count { it.isNotEmpty() }.coerceAtLeast(1)
            val folders = mutableListOf<Folder>()
            var current = parent
            val pieces = label.trim('/').split('/')
            for (level in depth downTo 1) {
                val name = pieces.take(level).joinToString("/") + "/"
                val id = current?.let { directory ->
                    folderIds.getOrPut("$actualVolume|${directory.path}") {
                        try {
                            val stat = Os.stat(directory.canonicalPath)
                            check(OsConstants.S_ISDIR(stat.st_mode) && stat.st_ino != 0L)
                            "dir|$actualVolume|${stat.st_dev}|${stat.st_ino}"
                        } catch (_: Exception) {
                            // Uncertain sources stay distinct; never blindly lowercase paths.
                            "path|$actualVolume|${directory.path}"
                        }
                    }
                } ?: "relative|$actualVolume|$name"
                folders.add(Folder(id, name, actualVolume))
                current = current?.parentFile
            }
            val self = folders.first()
            Album(self.id, label, actualVolume, folders.reversed())
        }
    }
}
