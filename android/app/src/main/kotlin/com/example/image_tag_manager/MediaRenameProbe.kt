package com.example.image_tag_manager

import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.pm.ApplicationInfo
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.system.Os
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest
import java.util.UUID

/** Experimental single-item update, never a production no-replace implementation. */
class MediaRenameProbe(private val context: Context) {
    companion object { const val ALBUM = "Pictures/ITM-M43-Test/" }
    private val resolver get() = context.contentResolver
    private val directory get() = File(context.filesDir, "m43-probe")

    private fun guard() {
        check(context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0) {
            "改名验证仅限 Debug 包"
        }
        check(Build.VERSION.SDK_INT >= 30) { "当前验证工具要求 Android 11 及以上" }
    }

    private fun snapshot(uri: Uri): JSONObject {
        val columns = arrayOf("_id", "_display_name", "relative_path", "volume_name", "_size", "owner_package_name", "generation_added", "generation_modified")
        val value = resolver.query(uri, columns, null, null, null)?.use { cursor ->
            check(cursor.count == 1 && cursor.moveToFirst()) { "媒体项缺失或不唯一" }
            JSONObject().apply {
                put("id", cursor.getLong(0))
                put("name", cursor.getString(1))
                put("album", cursor.getString(2))
                put("volume", cursor.getString(3))
                put("size", cursor.getLong(4))
                put("owner", cursor.getString(5) ?: JSONObject.NULL)
                put("generationAdded", cursor.getLong(6))
                put("generationModified", cursor.getLong(7))
            }
        } ?: error("无法查询媒体项")
        check(value.getString("album") == ALBUM) { "仅允许专用测试相册 $ALBUM" }
        check(value.getString("volume") == MediaStore.VOLUME_EXTERNAL_PRIMARY) {
            "当前验证仅支持主存储卷"
        }
        val concrete = ContentUris.withAppendedId(
            MediaStore.Images.Media.getContentUri(value.getString("volume")), value.getLong("id"),
        )
        value.put("uri", concrete.toString())
        value.put("storeVersion", MediaStore.getVersion(context, value.getString("volume")))
        resolver.openFileDescriptor(concrete, "r")?.use { descriptor ->
            val stat = Os.fstat(descriptor.fileDescriptor)
            value.put("device", stat.st_dev.toString())
            value.put("inode", stat.st_ino.toString())
        } ?: error("无法读取文件身份")
        val digest = MessageDigest.getInstance("SHA-256")
        resolver.openInputStream(concrete)?.use { input ->
            val buffer = ByteArray(65536)
            var total = 0L
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                total += count
                check(total <= 32L * 1024 * 1024) { "验证副本须不超过 32 MiB" }
                digest.update(buffer, 0, count)
            }
            value.put("bytesRead", total)
        } ?: error("无法读取测试副本")
        value.put("sha256", digest.digest().joinToString("") { "%02x".format(it) })
        return value
    }

    private fun planFile(token: String): File {
        require(Regex("[a-f0-9-]{36}").matches(token)) { "无效验证记录 ID" }
        return File(directory, "$token.json")
    }

    private fun append(token: String, value: JSONObject) {
        FileOutputStream(File(directory, "$token.events"), true).use {
            it.write((value.toString() + "\n").toByteArray(Charsets.UTF_8))
            it.fd.sync()
        }
    }

    @Synchronized fun prepare(id: Long, target: String): Map<String, Any> {
        guard()
        require(target.isNotBlank() && target != "." && target != ".." &&
            target.toByteArray(Charsets.UTF_8).size <= 240 &&
            target.none { it == '/' || it == '\\' || it.code < 32 }) { "测试目标名称无效" }
        val before = snapshot(ContentUris.withAppendedId(
            MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY), id,
        ))
        val original = before.getString("name")
        require(target != original) { "无需改名" }
        require(target.substringAfterLast('.').equals(original.substringAfterLast('.'), true)) {
            "验证不允许改变扩展名"
        }
        val token = UUID.randomUUID().toString()
        check(directory.isDirectory || directory.mkdirs()) { "无法创建验证记录目录" }
        val plan = JSONObject().put("version", 1).put("token", token)
            .put("before", before).put("target", target)
        FileOutputStream(planFile(token)).use {
            it.write(plan.toString().toByteArray(Charsets.UTF_8))
            it.fd.sync()
        }
        check(planFile(token).readText() == plan.toString()) { "验证计划保存核对失败" }
        return mapOf("token" to token, "details" to plan.toString(2))
    }

    @Synchronized fun authorizationUri(token: String): Uri {
        guard()
        val before = JSONObject(planFile(token).readText()).getJSONObject("before")
        val uri = Uri.parse(before.getString("uri"))
        val current = snapshot(uri)
        check(sameIdentity(before, current) && before.getString("name") == current.getString("name")) {
            "预演后测试副本已变化，请重新预演"
        }
        return uri
    }

    private fun sameIdentity(a: JSONObject, b: JSONObject) =
        listOf("uri", "storeVersion", "generationAdded", "device", "inode", "sha256", "bytesRead").all { a.get(it).toString() == b.get(it).toString() }

    @Synchronized fun execute(token: String): String {
        guard()
        val plan = JSONObject(planFile(token).readText())
        val before = plan.getJSONObject("before")
        val uri = authorizationUri(token)
        val target = plan.getString("target")
        // A visible-media check is intentionally not advertised as a filesystem no-replace guarantee.
        resolver.query(MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY),
            arrayOf("_id", "_display_name"), "relative_path = ?", arrayOf(ALBUM), null)?.use { cursor ->
            while (cursor.moveToNext()) {
                check(!cursor.getString(1).equals(target, true)) { "可见媒体中已有目标名，未执行" }
            }
        } ?: error("无法查询测试目录可见名称，未执行")
        append(token, JSONObject().put("event", "attempt").put("time", System.currentTimeMillis()))
        try {
            val count = resolver.update(uri, ContentValues().apply { put("_display_name", target) },
                "_display_name = ?", arrayOf(before.getString("name")))
            val after = snapshot(uri)
            val exact = count == 1 && after.getString("name") == target && sameIdentity(before, after)
            val result = JSONObject().put("event", "checked").put("updated", count)
                .put("exactNameAndIdentity", exact).put("after", after)
            append(token, result)
            return result.toString(2)
        } catch (error: Exception) {
            append(token, JSONObject().put("event", "failedOrUncertain")
                .put("reason", error.message ?: error.javaClass.simpleName))
            return "调用失败或结果未确认：${error.message}\n请使用“核对验证记录”；不自动重试或恢复。"
        }
    }

    @Synchronized fun inspect(): String {
        guard()
        return directory.listFiles()?.filter { it.extension == "json" }?.sortedBy { it.name }
            ?.joinToString("\n\n") { file ->
                try {
                    val plan = JSONObject(file.readText())
                    val before = plan.getJSONObject("before")
                    val report = JSONObject().put("plan", plan)
                    try {
                        val current = snapshot(Uri.parse(before.getString("uri")))
                        report.put("current", current).put("sameIdentity", sameIdentity(before, current))
                    } catch (error: Exception) {
                        report.put("currentIssue", "无法可靠核对：${error.message}；不自动恢复")
                    }
                    val events = File(directory, "${file.nameWithoutExtension}.events")
                    report.toString(2) + "\n事件：\n" + if (events.exists()) events.readText() else "尚无执行事件"
                } catch (error: Exception) {
                    "${file.name}：无法可靠核对：${error.message}；保留记录，人工检查。"
                }
            }?.ifEmpty { "暂无验证记录" } ?: "暂无验证记录"
    }
}
