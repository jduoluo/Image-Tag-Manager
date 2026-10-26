package com.example.image_tag_manager

import android.content.ContentValues
import android.content.ContentUris
import android.content.Context
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.media.MediaScannerConnection
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Same-directory MediaStore renames with identity and exact-result verification. */
class AndroidSafeRename(private val context: Context) {
    companion object { private val nativeLoaded = runCatching { System.loadLibrary("itm_safe_rename") }.isSuccess }
    private external fun nativeIdentity(path: ByteArray): String
    private external fun nativeReadableIdentity(path: ByteArray): String

    private val resolver get() = context.contentResolver
    private val collection get() = MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL)

    private fun path(value: String): File {
        check(Build.VERSION.SDK_INT >= 30) { "原图打标要求 Android 11 及以上" }
        val file = File(value)
        check(file.isAbsolute && !value.contains('\u0000') &&
            !value.split('/').contains("..") && value.startsWith("/storage/")) {
            "仅支持系统共享存储中的普通媒体文件"
        }
        check(file.canonicalPath == value) { "不支持链接或非规范媒体路径" }
        return file
    }

    fun identity(value: String): String {
        check(nativeLoaded) { "当前设备无法加载安全改名组件，仅支持读取和导出" }
        val file = path(value)
        return MediaStore.getVersion(context) + "@" + nativeIdentity(file.path.toByteArray(Charsets.UTF_8))
    }

    fun metadata(value: String?): Map<String, Any> {
        if (Build.VERSION.SDK_INT < 30 || value == null) return emptyMap()
        return try {
            mapOf("path" to path(value).path, "fileId" to identity(value))
        } catch (_: Exception) { emptyMap() }
    }

    private val preparations = java.util.concurrent.ConcurrentHashMap<String, android.os.CancellationSignal>()
    fun beginPreparation(id: String) {
        check(preparations.size < 4 && preparations.putIfAbsent(id, android.os.CancellationSignal()) == null) {
            "图片准备请求已存在或过多"
        }
    }
    fun cancelPreparation(id: String) { preparations[id]?.cancel() }
    fun finishPreparation(id: String) { preparations.remove(id) }

    fun entries(ids: List<Long>, includeIdentity: Boolean = true, requestId: String? = null,
        progress: ((Int, Int) -> Unit)? = null): List<Map<String, Any>> {
        if (ids.isEmpty()) return emptyList()
        val cancellation = requestId?.let { preparations[it] ?: error("图片准备请求已结束") }
            ?: android.os.CancellationSignal()
        cancellation.throwIfCanceled()
        if (includeIdentity) check(Build.VERSION.SDK_INT >= 30 && nativeLoaded) { "此来源无法可靠核对文件身份" }
        val version = if (includeIdentity) MediaStore.getVersion(context) else ""
        val directories = mutableMapOf<String, MediaSourceNames>()
        val result = mutableListOf<Map<String, Any>>()
        MediaEntryBatch.forEach<Pair<String, String>>(ids, 300, { batch ->
            val found = mutableMapOf<Long, Pair<String, String>>()
            val selection = "_id IN (${batch.joinToString(",") { "?" }})"
            resolver.query(collection, arrayOf("_id", "_display_name", "_data"), selection,
                batch.map { it.toString() }.toTypedArray(), null, cancellation)?.use { cursor ->
                while (cursor.moveToNext()) {
                    cancellation.throwIfCanceled()
                    val id = cursor.getLong(0)
                    val name = cursor.getString(1) ?: error("媒体名称缺失：$id")
                    val data = cursor.getString(2) ?: error("此来源没有普通文件路径：$name")
                    check(found.put(id, name to data) == null) { "媒体 ID 对应多条记录：$id" }
                }
            } ?: error("无法查询图片身份")
            found
        }, { id, row ->
                val (name, data) = row
                if (!includeIdentity) {
                    result.add(mapOf("id" to id, "name" to name, "path" to data, "modifiedTime" to File(data).lastModified()))
                } else {
                    val file = path(data)
                    val fileId = "$version@${nativeIdentity(file.path.toByteArray(Charsets.UTF_8))}"
                    val directory = file.parentFile!!
                    val directoryId = fileId.substringAfterLast('@').split(':').take(2).joinToString(":")
                    val index = directories.getOrPut(directoryId) {
                        MediaSourceNames(directory.list()?.toList() ?: error("无法读取实际目录名称：$name"))
                    }
                    val actualName = index.resolve(name, file.name, fileId, { candidate ->
                        val candidateFile = path(File(directory, candidate).path)
                        "$version@${nativeIdentity(candidateFile.path.toByteArray(Charsets.UTF_8))}"
                    }, { candidate ->
                        val candidateFile = path(File(directory, candidate).path)
                        "$version@${nativeReadableIdentity(candidateFile.path.toByteArray(Charsets.UTF_8))}"
                    })
                    result.add(mapOf("id" to id, "name" to actualName,
                        "path" to File(directory, actualName).path, "fileId" to fileId))
                }
                if (result.size % 50 == 0 || result.size == ids.size) progress?.invoke(result.size, ids.size)
        }, { cancellation.throwIfCanceled() })
        cancellation.throwIfCanceled()
        if (includeIdentity) check(MediaStore.getVersion(context) == version) { "系统媒体库已重建，请重新选择图片" }
        return result
    }

    /** Merge visible names with readable, same-directory MediaStore path aliases. */
    fun directoryNames(value: String): List<String> {
        check(nativeLoaded) { "安全改名组件不可用" }
        val root = path(value)
        val rootStat = android.system.Os.stat(root.path)
        check(android.system.OsConstants.S_ISDIR(rootStat.st_mode) && rootStat.st_ino != 0L) { "目录身份不可用" }
        val names = linkedSetOf<String>()
        names.addAll(root.list()?.toList() ?: error("无法读取目录名称"))
        val known = names.map { it.uppercase(java.util.Locale.ROOT) }.toMutableSet()
        val parents = mutableMapOf<String, Boolean>()
        val prefix = root.path.replace("!", "!!").replace("%", "!%").replace("_", "!_") + "/%"
        resolver.query(collection, arrayOf("_data"), "LOWER(_data) LIKE LOWER(?) ESCAPE '!'", arrayOf(prefix), null)?.use { cursor ->
            while (cursor.moveToNext()) {
                val data = cursor.getString(0) ?: continue
                val candidate = File(data)
                val parent = candidate.parentFile ?: continue
                if (!parent.path.equals(root.path, ignoreCase = true)) continue
                if (candidate.name.uppercase(java.util.Locale.ROOT) in known) continue
                try {
                    val sameDirectory = parents.getOrPut(parent.path) {
                        val stat = android.system.Os.stat(path(parent.path).path)
                        android.system.OsConstants.S_ISDIR(stat.st_mode) &&
                            stat.st_dev == rootStat.st_dev && stat.st_ino == rootStat.st_ino
                    }
                    if (!sameDirectory) continue
                    val raw = path(data)
                    val opened = nativeReadableIdentity(raw.path.toByteArray(Charsets.UTF_8))
                    val normalized = path(File(root, candidate.name).path)
                    if (raw.path != normalized.path &&
                        opened != nativeReadableIdentity(normalized.path.toByteArray(Charsets.UTF_8))) continue
                    names.add(candidate.name)
                    known.add(candidate.name.uppercase(java.util.Locale.ROOT))
                } catch (_: Exception) {
                    // Never invent an entry from an inaccessible/stale database row.
                }
            }
        } ?: error("无法核对目录中的媒体路径")
        return names.toList()
    }

    fun urisForPaths(paths: List<String>): List<Uri> {
        check(paths.isNotEmpty() && paths.size <= 2000) { "本次授权数量无效" }
        return paths.map { value ->
            val file = path(value)
            check(file.isFile) { "原文件已不存在，请重新核对" }
            findMediaUri(value) ?: run { scan(listOf(file.path)); findMediaUri(value) }
                ?: error("媒体库未同步此文件，无法请求修改授权")
        }
    }

    // Names must remain exact; only parent paths may be proven aliases by stat.
    private fun sameMediaPath(first: String, second: String): Boolean {
        if (first == second) return true
        val left = path(first)
        val right = path(second)
        if (left.name != right.name) return false
        val a = android.system.Os.stat(left.parent!!)
        val b = android.system.Os.stat(right.parent!!)
        return android.system.OsConstants.S_ISDIR(a.st_mode) &&
            android.system.OsConstants.S_ISDIR(b.st_mode) && a.st_ino != 0L &&
            a.st_dev == b.st_dev && a.st_ino == b.st_ino
    }

    private fun sameSourcePath(first: String, second: String): Boolean {
        if (sameMediaPath(first, second)) return true
        val left = path(first)
        val right = path(second)
        if (!left.name.equals(right.name, ignoreCase = true)) return false
        // Compare parents through an identical leaf, then prove both spellings address the same file.
        if (!sameMediaPath(first, File(right.parentFile, left.name).path)) return false
        return identity(first) == identity(second)
    }

    private fun findMediaUri(value: String): Uri? {
        fun find(selection: String): Uri? = resolver.query(collection,
            arrayOf("_id", "volume_name", "_data"), selection, arrayOf(value), null)?.use { cursor ->
            if (cursor.count != 1 || !cursor.moveToFirst()) null else {
                val actual = cursor.getString(2) ?: return@use null
                if (!sameSourcePath(value, actual)) null else
                    ContentUris.withAppendedId(MediaStore.Images.Media.getContentUri(cursor.getString(1)), cursor.getLong(0))
            }
        }
        // A case-insensitive query is only candidate discovery, never identity proof.
        return find("_data = ?") ?: find("_data = ? COLLATE NOCASE")
    }

    private fun mediaRow(uri: Uri): MediaStoreRenameOperation.Row? = resolver.query(
        uri, arrayOf("_id", "_data", "_display_name", "volume_name"), null, null, null,
    )?.use { cursor ->
        if (cursor.count != 1 || !cursor.moveToFirst()) null else {
            val specific = ContentUris.withAppendedId(
                MediaStore.Images.Media.getContentUri(cursor.getString(3)), cursor.getLong(0))
            MediaStoreRenameOperation.Row(specific.toString(), cursor.getString(1), cursor.getString(2))
        }
    }

    @Synchronized fun rename(source: String, target: String, expectedId: String) {
        val from = path(source)
        val to = path(target)
        check(from.parent == to.parent && source != target) { "只支持同目录改名" }
        check(to.name.toByteArray(Charsets.UTF_8).size <= 255 && to.name.isNotEmpty()) { "目标文件名无效" }
        val backend = object : MediaStoreRenameOperation.Backend {
            override fun samePath(first: String, second: String): Boolean = sameMediaPath(first, second)
            override fun matchesSource(source: String, row: MediaStoreRenameOperation.Row): Boolean =
                File(source).name.equals(row.name, ignoreCase = true) &&
                File(row.path).name.equals(row.name, ignoreCase = true) && sameSourcePath(source, row.path)
            override fun rowForPath(value: String): MediaStoreRenameOperation.Row? {
                val uri = findMediaUri(value) ?: return null
                return mediaRow(uri)
            }
            override fun rowForUri(uri: String) = mediaRow(Uri.parse(uri))
            override fun identityOrNull(value: String): String? {
                try {
                    // lstat sees dangling links too; existence checks must not follow them.
                    android.system.Os.lstat(value)
                } catch (error: android.system.ErrnoException) {
                    if (error.errno == android.system.OsConstants.ENOENT) return null
                    throw error
                }
                return identity(value)
            }
            override fun directoryNames(value: String): List<String> =
                File(value).parentFile!!.list()?.toList() ?: error("无法读取目录名称，未执行改名")
            override fun update(before: MediaStoreRenameOperation.Row, targetName: String): Int =
                resolver.update(Uri.parse(before.uri), ContentValues().apply {
                    put(MediaStore.MediaColumns.DISPLAY_NAME, targetName)
                }, "_data = ? AND _display_name = ?", arrayOf(before.path, before.name))
        }
        MediaStoreRenameOperation.rename(backend, source, target, expectedId)
        // MediaStore owns the row update; full reconciliation is requested after the batch.
    }
    private fun scan(paths: List<String>): Boolean {
        if (paths.isEmpty()) return true
        val completed = CountDownLatch(paths.size)
        MediaScannerConnection.scanFile(context, paths.toTypedArray(), null) { _, _ -> completed.countDown() }
        return completed.await(10, TimeUnit.SECONDS)
    }

    private fun indexedPaths(paths: List<String>): Set<String> {
        val good = mutableSetOf<String>()
        for (batch in paths.chunked(400)) {
            if (batch.isEmpty()) continue
            val counts = mutableMapOf<String, Int>()
            val names = mutableMapOf<String, String>()
            resolver.query(collection, arrayOf("_data", "_display_name"),
                "_data IN (${batch.joinToString(",") { "?" }})", batch.toTypedArray(), null)?.use { cursor ->
                while (cursor.moveToNext()) {
                    val value = cursor.getString(0) ?: continue
                    counts[value] = (counts[value] ?: 0) + 1
                    names[value] = cursor.getString(1) ?: ""
                }
            } ?: error("无法核对媒体库名称")
            for (value in batch) if (counts[value] == 1 && names[value] == File(value).name) good.add(value)
        }
        return good
    }

    fun refresh(paths: List<String>): String {
        val existing = paths.distinct().map { path(it).path }.filter { File(it).isFile }
        val good = MediaRefreshOperation.refresh(existing, object : MediaRefreshOperation.Backend {
            override fun indexed(paths: List<String>): Set<String> = indexedPaths(paths)
            override fun scan(paths: List<String>): Boolean = this@AndroidSafeRename.scan(paths)
        })
        return if (good) "" else "文件状态已核对，但媒体库刷新尚未完成。请稍后刷新；记录和实际文件状态保留。"
    }
}
