package com.example.image_tag_manager

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.ContentUris
import android.content.ContentValues
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaScannerConnection
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream

/** MediaStore browsing/export and explicitly authorized safe rename adapter. */
class MainActivity : FlutterActivity() {
    private val mediaRevision = java.util.concurrent.atomic.AtomicLong(0)
    private var cachedMediaRows: List<Map<String, Any>>? = null
    private var cachedMediaRevision = -1L
    private var cachedMediaPermission = ""
    private val changeHandler = Handler(Looper.getMainLooper())
    private var changeSink: io.flutter.plugin.common.EventChannel.EventSink? = null
    private val emitChange = Runnable { changeSink?.success(mediaRevision.get().toString()) }
    @Synchronized private fun invalidateRows() { cachedMediaRevision = -1L }
    private fun revisionSignature(): String {
        val version = if (Build.VERSION.SDK_INT >= 29) MediaStore.getVersion(this) else "legacy"
        val generation = if (Build.VERSION.SDK_INT >= 30) MediaStore.getExternalVolumeNames(this).sorted()
            .joinToString(",") { "$it:${MediaStore.getGeneration(this, it)}" } else "legacy"
        return "${permissionState()}|$version|$generation|${mediaRevision.get()}"
    }
    private var observingMedia = false
    private val mediaObserver = object : android.database.ContentObserver(Handler(Looper.getMainLooper())) {
        override fun onChange(selfChange: Boolean) {
            mediaRevision.incrementAndGet()
            changeHandler.removeCallbacks(emitChange)
            changeHandler.postDelayed(emitChange, 250)
        }
    }
    override fun onDestroy() {
        if (observingMedia) contentResolver.unregisterContentObserver(mediaObserver)
        changeHandler.removeCallbacks(emitChange)
        changeSink = null
        super.onDestroy()
    }
    private val channelName = "image_tag_manager/android_media_probe"
    private val requestCode = 49136
    private val exportPermissionCode = 49137
    private val configExportCode = 49138
    private val originalImageReader by lazy { OriginalImageReader(this) }
    private val exportCleanup by lazy { ExportCleanup(this) }
    private val safeRename by lazy { AndroidSafeRename(this) }
    private val renameWriteCode = 49140
    private var pendingRenameWriteResult: MethodChannel.Result? = null
    private var pendingPermissionResult: MethodChannel.Result? = null
    private var pendingExportPermissionResult: MethodChannel.Result? = null
    private var pendingConfigExportResult: MethodChannel.Result? = null
    private var pendingConfigExportContents: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "image_tag_manager/app_information")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "version" -> {
                        @Suppress("DEPRECATION")
                        val info = packageManager.getPackageInfo(packageName, 0)
                        result.success(info.versionName)
                    }
                    "openUrl" -> {
                        val url = call.arguments as? String
                        if (url != "https://github.com/jduoluo/Image-Tag-Manager" &&
                            url != "https://github.com/jduoluo/Image-Tag-Manager/issues") {
                            result.error("invalid_url", "Only project URLs are supported", null)
                        } else {
                            try {
                                startActivity(Intent(Intent.ACTION_VIEW, android.net.Uri.parse(url)).apply {
                                    addCategory(Intent.CATEGORY_BROWSABLE)
                                })
                                result.success(null)
                            } catch (error: Exception) {
                                result.error("open_failed", "Could not open browser", null)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        if (!observingMedia) {
            contentResolver.registerContentObserver(android.net.Uri.parse("content://media"), true, mediaObserver)
            observingMedia = true
        }
        io.flutter.plugin.common.EventChannel(flutterEngine.dartExecutor.binaryMessenger,
            "image_tag_manager/media_changes").setStreamHandler(object : io.flutter.plugin.common.EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: io.flutter.plugin.common.EventChannel.EventSink) { changeSink = events }
            override fun onCancel(arguments: Any?) { changeSink = null; changeHandler.removeCallbacks(emitChange) }
        })
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler(::handleProbeCall)
        val renameChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "image_tag_manager/android_safe_rename")
        renameChannel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "entries" -> {
                        val requestId = call.argument<String>("requestId")
                        try {
                            if (requestId != null) safeRename.beginPreparation(requestId)
                            background(result) {
                                try {
                                    safeRename.entries(call.argument<List<Number>>("ids")!!.map { it.toLong() },
                                        call.argument<Boolean>("includeIdentity") != false, requestId) { done, total ->
                                        if (requestId != null) changeHandler.post {
                                            renameChannel.invokeMethod("entryPreparationProgress",
                                                mapOf("requestId" to requestId, "done" to done, "total" to total))
                                        }
                                    }
                                } finally {
                                    if (requestId != null) safeRename.finishPreparation(requestId)
                                }
                            }
                        } catch (error: Exception) {
                            result.error("preparation_failed", error.message, null)
                        }
                    }
                    "cancelPreparation" -> {
                        safeRename.cancelPreparation(call.argument<String>("requestId")!!)
                        result.success(null)
                    }
                    "directoryNames" -> background(result) {
                        safeRename.directoryNames(call.argument<String>("directory")!!)
                    }
                    "identity" -> background(result) { safeRename.identity(call.argument<String>("path")!!) }
                    "rename" -> background(result) {
                        safeRename.rename(call.argument<String>("source")!!, call.argument<String>("target")!!,
                            call.argument<String>("expectedId")!!)
                        true
                    }
                    "authorize" -> requestRenameWrite(call, result)
                    "refresh" -> background(result) { safeRename.refresh(call.argument<List<String>>("paths")!!) }
                    else -> result.notImplemented()
                }
            }
    }

    private fun requestRenameWrite(call: MethodCall, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < 30) {
            result.error("unsupported", "原图打标要求 Android 11 及以上", null)
            return
        }
        if (pendingRenameWriteResult != null) {
            result.error("busy", "系统修改授权正在进行", null)
            return
        }
        pendingRenameWriteResult = result
        Thread {
            try {
                val uris = safeRename.urisForPaths(call.argument<List<String>>("paths")!!)
                Handler(Looper.getMainLooper()).post {
                    try {
                        val request = MediaStore.createWriteRequest(contentResolver, uris)
                        startIntentSenderForResult(request.intentSender, renameWriteCode, null, 0, 0, 0)
                    } catch (error: Exception) {
                        pendingRenameWriteResult = null
                        result.error("authorization_failed", error.message, null)
                    }
                }
            } catch (error: Exception) {
                Handler(Looper.getMainLooper()).post {
                    pendingRenameWriteResult = null
                    result.error("authorization_failed", error.message, null)
                }
            }
        }.start()
    }
    private fun handleProbeCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "loadImageSort" -> result.success(getSharedPreferences("browser", MODE_PRIVATE).getString("imageSort", null))
            "saveImageSort" -> {
                getSharedPreferences("browser", MODE_PRIVATE).edit().putString("imageSort", call.argument<String>("value")).apply()
                result.success(null)
            }
            "permissionState" -> result.success(permissionState())
            "requestImages" -> requestImages(result)
            "mediaRevision" -> background(result) { revisionSignature() }
            "invalidateMediaCache" -> { invalidateRows(); result.success(null) }
            "listAlbums" -> background(result) { listAlbums() }
            "listAllImages" -> background(result) { listAllImages() }
            "listImages" -> background(result) {
                val album = call.argument<String>("album") ?: error("缺少相册位置")
                listImages(album)
            }
            "openOriginalImage" -> background(result) {
                if (permissionState() == "denied") error("照片权限已失效")
                val id = call.argument<Number>("id")?.toLong() ?: error("缺少图片 ID")
                originalImageReader.open(ContentUris.withAppendedId(imageCollection(), id))
            }
            "closeOriginalImage" -> background(result) {
                originalImageReader.close(call.argument<String>("token") ?: error("缺少查看令牌"))
                null
            }
            "thumbnail" -> background(result) {
                val id = call.argument<Number>("id")?.toLong() ?: error("缺少图片 ID")
                thumbnail(id)
            }
            "previewExportCleanup" -> background(result) { exportCleanup.preview() }
            "deleteExportCopies" -> background(result) { exportCleanup.execute(
                call.argument<String>("token") ?: error("缺少预览"),
                call.argument<List<Number>>("ids")?.map { it.toLong() } ?: error("缺少选择")) }
            "privateConfigDirectory" -> result.success(filesDir.absolutePath)
            "requestExportPermission" -> requestExportPermission(result)
            "exportConfig" -> exportConfig(call, result)
            "exportImages" -> background(result) {
                val ids = call.argument<List<Number>>("ids")?.map { it.toLong() }
                    ?: error("缺少图片 ID")
                exportImages(ids)
            }
            else -> result.notImplemented()
        }
    }

    private fun background(result: MethodChannel.Result, work: () -> Any?) {
        Thread {
            try {
                val value = work()
                Handler(Looper.getMainLooper()).post { result.success(value) }
            } catch (error: Exception) {
                Handler(Looper.getMainLooper()).post {
                    result.error(if (error is android.os.OperationCanceledException) "preparation_cancelled" else "media_operation_failed", error.message ?: "媒体操作失败",
                        mapOf("requiresInspection" to (error is MediaStoreRenameOperation.UncertainResultException)))
                }
            }
        }.start()
    }

    private fun permissionState(): String {
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.READ_MEDIA_IMAGES) == PackageManager.PERMISSION_GRANTED
        ) return "full"
        if (Build.VERSION.SDK_INT >= 34 &&
            checkSelfPermission(Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED) == PackageManager.PERMISSION_GRANTED
        ) return "partial"
        if (Build.VERSION.SDK_INT < 33 &&
            checkSelfPermission(Manifest.permission.READ_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED
        ) return "full"
        return "denied"
    }

    private fun requestImages(result: MethodChannel.Result) {
        if (pendingPermissionResult != null) {
            result.error("busy", "已有照片权限请求正在进行", null)
            return
        }
        pendingPermissionResult = result
        val permissions = when {
            Build.VERSION.SDK_INT >= 34 -> arrayOf(
                Manifest.permission.READ_MEDIA_IMAGES,
                Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED,
            )
            Build.VERSION.SDK_INT >= 33 -> arrayOf(Manifest.permission.READ_MEDIA_IMAGES)
            else -> arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE)
        }
        requestPermissions(permissions, requestCode)
    }

    private fun requestExportPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT >= 29 ||
            checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED
        ) {
            result.success(true)
            return
        }
        if (pendingExportPermissionResult != null) {
            result.error("busy", "已有写入权限请求正在进行", null)
            return
        }
        pendingExportPermissionResult = result
        requestPermissions(arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE), exportPermissionCode)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        when (requestCode) {
            this.requestCode -> {
                pendingPermissionResult?.success(permissionState())
                pendingPermissionResult = null
            }
            exportPermissionCode -> {
                pendingExportPermissionResult?.success(
                    grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED
                )
                pendingExportPermissionResult = null
            }
        }
    }

    private fun exportConfig(call: MethodCall, result: MethodChannel.Result) {
        if (pendingConfigExportResult != null) {
            result.error("busy", "已有配置导出请求正在进行", null)
            return
        }
        val contents = call.argument<String>("contents")
        if (contents == null) {
            result.error("invalid_argument", "缺少配置内容", null)
            return
        }
        pendingConfigExportResult = result
        pendingConfigExportContents = contents
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "application/json"
            putExtra(Intent.EXTRA_TITLE, "tag_groups.json")
        }
        try {
            startActivityForResult(intent, configExportCode)
        } catch (error: Exception) {
            pendingConfigExportResult = null
            pendingConfigExportContents = null
            result.error("config_export_failed", error.message ?: "无法打开保存界面", null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == renameWriteCode) {
            val result = pendingRenameWriteResult
            pendingRenameWriteResult = null
            result?.success(resultCode == Activity.RESULT_OK)
            return
        }
        if (requestCode != configExportCode) return
        val result = pendingConfigExportResult ?: return
        val contents = pendingConfigExportContents
        pendingConfigExportResult = null
        pendingConfigExportContents = null
        if (resultCode != Activity.RESULT_OK) {
            result.success(false)
            return
        }
        try {
            val uri = data?.data ?: error("未取得保存位置")
            val bytes = contents?.toByteArray(Charsets.UTF_8) ?: error("配置内容已丢失")
            contentResolver.openOutputStream(uri, "wt")?.use { output ->
                output.write(bytes)
                output.flush()
            } ?: error("无法写入配置文件")
            result.success(true)
        } catch (error: Exception) {
            result.error("config_export_failed", error.message ?: "导出配置失败", null)
        }
    }
    private fun imageCollection() = if (Build.VERSION.SDK_INT >= 29) {
        MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL)
    } else {
        MediaStore.Images.Media.EXTERNAL_CONTENT_URI
    }

    private fun albumColumn() = if (Build.VERSION.SDK_INT >= 29) {
        MediaStore.Images.Media.RELATIVE_PATH
    } else {
        MediaStore.Images.Media.BUCKET_DISPLAY_NAME
    }

    @Synchronized private fun queryMediaRows(albumId: String? = null): List<Map<String, Any>> {
        val revision = mediaRevision.get()
        val permission = permissionState()
        val cached = cachedMediaRows
        if (cached != null && cachedMediaRevision == revision && cachedMediaPermission == permission) {
            return if (albumId == null) cached else cached.filter { it["album"] == albumId || it["albumName"] == albumId }
        }
        if (permissionState() == "denied") error("尚未获得照片读取权限")
        val catalog = MediaAlbumCatalog()
        val rows = mutableListOf<Map<String, Any>>()
        val projection = mutableListOf(
            MediaStore.Images.Media._ID, MediaStore.Images.Media.DISPLAY_NAME,
            albumColumn(), MediaStore.Images.Media.DATA,
        )
        if (Build.VERSION.SDK_INT >= 29) projection.add(MediaStore.MediaColumns.VOLUME_NAME)
        val storeVersion = if (Build.VERSION.SDK_INT >= 29) MediaStore.getVersion(this) else "legacy"
        val sizeIndex = projection.size
        projection.add("_size")
        val modifiedIndex = projection.size
        projection.add("date_modified")
        val generationIndex = if (Build.VERSION.SDK_INT >= 30) projection.size else -1
        if (generationIndex >= 0) projection.add("generation_modified")
        val sortOrder = "${MediaStore.Images.Media.DATE_ADDED} DESC, ${MediaStore.Images.Media._ID} DESC"
        contentResolver.query(imageCollection(), projection.toTypedArray(), null, null, sortOrder)?.use { cursor ->
            while (cursor.moveToNext()) {
                val album = catalog.album(cursor.getString(2), cursor.getString(3),
                    if (Build.VERSION.SDK_INT >= 29) cursor.getString(4) else null)

                val info: Map<String, Any> = cursor.getString(3)?.let { mapOf("path" to it) } ?: emptyMap()
                rows.add(mapOf(
                    "id" to cursor.getLong(0),
                    "name" to (cursor.getString(1) ?: "未命名图片"),
                    "album" to album.id,
                    "changeToken" to "$storeVersion:${cursor.getString(sizeIndex)}:${cursor.getString(modifiedIndex)}:${if (generationIndex >= 0) cursor.getString(generationIndex) else "legacy"}",
                    "modifiedTime" to cursor.getLong(modifiedIndex) * 1000L,
                    "albumName" to album.name,
                    "volume" to album.volume,
                    "folders" to album.folders.map { it.map() },
                ) + info)
            }
        } ?: error("媒体库查询失败")
        cachedMediaRows = rows
        cachedMediaRevision = revision
        cachedMediaPermission = permission
        return if (albumId == null) rows else rows.filter { it["album"] == albumId || it["albumName"] == albumId }
    }
    private fun listAlbums(): List<Map<String, Any>> = queryMediaRows().groupBy { it["album"] as String }
        .map { (id, rows) ->
            val representative = rows.minBy { it["albumName"] as String }
            mapOf("id" to id, "name" to representative["albumName"]!!, "count" to rows.size,
                "volume" to representative["volume"]!!, "folders" to representative["folders"]!!)
        }.sortedWith(compareBy({ (it["name"] as String).lowercase() }, { it["id"] as String }))

    private fun listAllImages(): List<Map<String, Any>> = queryMediaRows()
    private fun listImages(album: String): List<Map<String, Any>> = queryMediaRows(albumId = album)

    private fun thumbnail(id: Long): ByteArray {
        if (permissionState() == "denied") error("照片权限已失效")
        val uri = ContentUris.withAppendedId(imageCollection(), id)
        val bitmap = if (Build.VERSION.SDK_INT >= 29) {
            contentResolver.loadThumbnail(uri, android.util.Size(256, 256), null)
        } else {
            @Suppress("DEPRECATION")
            MediaStore.Images.Thumbnails.getThumbnail(
                contentResolver, id, MediaStore.Images.Thumbnails.MINI_KIND, null,
            ) ?: contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it) }
        } ?: error("无法读取缩略图")
        return ByteArrayOutputStream().use { output ->
            bitmap.compress(Bitmap.CompressFormat.JPEG, 75, output)
            bitmap.recycle()
            output.toByteArray()
        }
    }

    private fun exportImages(ids: List<Long>): Map<String, Any> {
        if (permissionState() == "denied") error("照片权限已失效")
        if (Build.VERSION.SDK_INT < 29 &&
            checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED
        ) error("尚未取得公共目录写入权限")
        val destination = "Pictures/TagQuickShare/"
        var copied = 0
        var skipped = 0
        val issues = mutableListOf<Map<String, String>>()
        for (id in ids.distinct()) {
            var filename = "ID $id"
            try {
                val source = ContentUris.withAppendedId(imageCollection(), id)
                var mimeType: String? = null
                val found = contentResolver.query(source, arrayOf(
                    MediaStore.Images.Media.DISPLAY_NAME,
                    MediaStore.Images.Media.MIME_TYPE,
                ), null, null, null)?.use { cursor ->
                    if (!cursor.moveToFirst()) false else {
                        filename = cursor.getString(0) ?: error("原图没有文件名")
                        mimeType = cursor.getString(1)
                        true
                    }
                } ?: false
                if (!found) error("原图已不可访问")
                if (filename == "." || filename == ".." || filename.contains('/') || filename.contains('\\')) {
                    error("原图文件名不安全")
                }
                if (exportExists(destination, filename)) {
                    skipped++
                    issues.add(mapOf("name" to filename, "reason" to "目标目录已有同名图片"))
                    continue
                }
                if (Build.VERSION.SDK_INT >= 29) exportModern(source, filename, mimeType, destination)
                else exportLegacy(source, filename)
                copied++
            } catch (error: Exception) {
                issues.add(mapOf("name" to filename, "reason" to (error.message ?: "复制失败")))
            }
        }
        return mapOf("copied" to copied, "skipped" to skipped, "issues" to issues)
    }

    private fun exportExists(destination: String, filename: String): Boolean {
        if (Build.VERSION.SDK_INT < 29) {
            val directory = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES), "TagQuickShare")
            return directory.listFiles()?.any { it.name.equals(filename, ignoreCase = true) } == true
        }
        contentResolver.query(
            MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY),
            arrayOf(MediaStore.Images.Media.DISPLAY_NAME),
            "${MediaStore.Images.Media.RELATIVE_PATH} = ?",
            arrayOf(destination), null,
        )?.use { cursor ->
            while (cursor.moveToNext()) if (cursor.getString(0).equals(filename, ignoreCase = true)) return true
        } ?: error("无法检查目标目录冲突")
        return false
    }

    private fun exportModern(source: android.net.Uri, filename: String, mimeType: String?, destination: String) {
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, filename)
            if (mimeType != null) put(MediaStore.Images.Media.MIME_TYPE, mimeType)
            put(MediaStore.Images.Media.RELATIVE_PATH, destination)
            put(MediaStore.Images.Media.IS_PENDING, 1)
        }
        val target = contentResolver.insert(
            MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY), values,
        ) ?: error("无法创建导出副本")
        try {
            contentResolver.openInputStream(source)?.use { input ->
                contentResolver.openOutputStream(target, "w")?.use { output -> input.copyTo(output) }
                    ?: error("无法写入导出副本")
            } ?: error("无法读取原图")
            val actualName = contentResolver.query(
                target, arrayOf(MediaStore.Images.Media.DISPLAY_NAME), null, null, null,
            )?.use { cursor -> if (cursor.moveToFirst()) cursor.getString(0) else null }
            if (actualName != filename) error("目标文件名发生变化，已撤销副本")
            val published = contentResolver.update(target, ContentValues().apply {
                put(MediaStore.Images.Media.IS_PENDING, 0)
            }, null, null)
            if (published != 1) error("无法公开导出副本")
        } catch (error: Exception) {
            contentResolver.delete(target, null, null)
            throw error
        }
    }

    private fun exportLegacy(source: android.net.Uri, filename: String) {
        val directory = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES), "TagQuickShare")
        if (!directory.exists() && !directory.mkdirs()) error("无法创建导出目录")
        val target = File(directory, filename)
        if (!target.createNewFile()) error("目标目录已有同名文件")
        try {
            contentResolver.openInputStream(source)?.use { input ->
                FileOutputStream(target).use { output -> input.copyTo(output) }
            } ?: error("无法读取原图")
            MediaScannerConnection.scanFile(this, arrayOf(target.absolutePath), null, null)
        } catch (error: Exception) {
            target.delete()
            throw error
        }
    }
}
