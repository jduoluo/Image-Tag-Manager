package com.example.image_tag_manager

import android.content.ContentUris
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.SystemClock
import android.provider.MediaStore
import android.system.Os
import android.system.OsConstants
import java.io.File
import java.util.UUID

/** Explicit, preview-bound deletion of this application's published export copies only. */
class ExportCleanup(private val context: Context) {
    private val destination = "Pictures/TagQuickShare/"
    private val resolver get() = context.contentResolver
    private val collection get() = MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
    private data class Candidate(val values: Map<String, String?>, val identity: String) {
        val id get() = values.getValue("_id")!!.toLong()
        fun display(): Map<String, Any> = mapOf("id" to id, "name" to values.getValue("_display_name")!!,
            "size" to values.getValue("_size")!!.toLong())
    }
    private data class Preview(val at: Long, val rows: Map<Long, Candidate>)
    private val previews = linkedMapOf<String, Preview>()
    private fun columns(): Array<String> = (listOf("_id", "_display_name", "_size", "date_added", "date_modified",
        "relative_path", "owner_package_name", "_data", "is_pending") +
        if (Build.VERSION.SDK_INT >= 30) listOf("generation_added", "generation_modified") else emptyList()).toTypedArray()
    private fun identity(path: String): String {
        val file = File(path)
        check(file.canonicalPath == path && path.startsWith("/storage/")) { "文件路径无法可靠核对" }
        val stat = Os.lstat(path)
        check(OsConstants.S_ISREG(stat.st_mode) && stat.st_ino != 0L) { "不是普通导出副本" }
        return "${stat.st_dev}:${stat.st_ino}:${stat.st_size}:${stat.st_mtim.tv_sec}:${stat.st_mtim.tv_nsec}"
    }
    private fun candidate(values: Map<String, String?>): Candidate? {
        if (!ExportCleanupPolicy.eligible(values, context.packageName)) return null
        val path = values["_data"] ?: return null
        if (File(path).name != values["_display_name"] || File(path).parentFile?.name != "TagQuickShare") return null
        return Candidate(values, identity(path))
    }
    private fun read(uri: Uri, selection: String? = null, args: Array<String>? = null): List<Map<String, String?>> {
        val columns = columns()
        return resolver.query(uri, columns, selection, args, "_id ASC")?.use { cursor ->
            buildList { while (cursor.moveToNext()) add(columns.mapIndexed { i, col ->
                col to if (cursor.isNull(i)) null else cursor.getString(i)
            }.toMap()) }
        } ?: error("无法查询导出副本")
    }
    @Synchronized fun preview(): Map<String, Any> {
        check(Build.VERSION.SDK_INT >= 29) { "Android 10 以下无法可靠识别副本归属，请使用系统相册手动管理" }
        val all = read(collection, "relative_path = ?", arrayOf(destination))
        val rows = all.mapNotNull { runCatching { candidate(it) }.getOrNull() }
        val token = UUID.randomUUID().toString()
        while (previews.size >= 4) previews.remove(previews.keys.first())
        previews[token] = Preview(SystemClock.elapsedRealtime(), rows.associateBy { it.id })
        return mapOf("token" to token, "items" to rows.map { it.display() }, "excluded" to (all.size - rows.size))
    }
    @Synchronized fun execute(token: String, ids: List<Long>): Map<String, Any> {
        check(Build.VERSION.SDK_INT >= 29) { "此系统不支持归属核验清理" }
        val preview = previews[token] ?: error("清理预览已失效，请重新预览")
        check(SystemClock.elapsedRealtime() - preview.at <= 600000) { "清理预览已过期，请重新预览" }
        check(ExportCleanupPolicy.selectionAllowed(preview.rows.keys, ids)) {
            "只能清理已预览并选中的副本，每批最多 50 张"
        }
        var deleted = 0
        val deletedIds = mutableListOf<Long>()
        val issues = mutableListOf<Map<String, String>>()
        for (id in ids) {
            val before = preview.rows.getValue(id)
            try {
                val uri = ContentUris.withAppendedId(collection, id)
                val values = read(uri).singleOrNull() ?: error("副本已不存在或不可访问")
                val current = candidate(values) ?: error("副本归属或位置变化，已跳过")
                check(ExportCleanupPolicy.unchanged(before.values, current.values, before.identity, current.identity, context.packageName)) { "预览后副本已变化，已跳过" }
                val args = mutableListOf<String>()
                val where = before.values.entries.joinToString(" AND ") { (key, value) ->
                    if (value == null) "$key IS NULL" else { args.add(value); "$key = ?" }
                }
                check(resolver.delete(uri, where, args.toTypedArray()) == 1) { "系统未确认删除，已停止处理本项" }
                deleted++
                deletedIds.add(id)
            } catch (error: Exception) {
                issues.add(mapOf("name" to before.values.getValue("_display_name")!!, "reason" to (error.message ?: "清理失败")))
            }
        }
        return mapOf("deleted" to deleted, "deletedIds" to deletedIds, "issues" to issues)
    }
}
