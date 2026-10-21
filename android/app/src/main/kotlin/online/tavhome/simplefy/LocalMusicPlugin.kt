package online.tavhome.simplefy

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** Import only user-selected documents; copying and metadata never run on the UI thread. */
class LocalMusicPlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler,
    PluginRegistry.ActivityResultListener {
    private lateinit var context: Context
    private lateinit var channel: MethodChannel
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var activity: ActivityPluginBinding? = null
    private var pending: MethodChannel.Result? = null
    private var cancellation = AtomicBoolean(false)
    private var folderMode = false

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "online.tavhome.simplefy/local_music")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        cancellation.set(true)
        pending = null
        channel.setMethodCallHandler(null)
        worker.shutdown()
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding
        binding.addActivityResultListener(this)
    }
    override fun onDetachedFromActivityForConfigChanges() {
        activity?.removeActivityResultListener(this)
        activity = null
    }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)
    override fun onDetachedFromActivity() {
        onDetachedFromActivityForConfigChanges()
        cancellation.set(true)
        pending?.error("cancelled", "Import interrupted. Choose the files again.", null)
        pending = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "importFolder" && call.method != "importFiles") {
            result.notImplemented()
            return
        }
        if (pending != null) {
            result.error("busy", "The file picker is already open", null)
            return
        }
        val host = activity?.activity
        if (host == null) {
            result.error("unavailable", "Could not open the file picker", null)
            return
        }
        folderMode = call.method == "importFolder"
        val intent = Intent(if (folderMode) Intent.ACTION_OPEN_DOCUMENT_TREE else Intent.ACTION_OPEN_DOCUMENT)
        intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        if (!folderMode) {
            intent.addCategory(Intent.CATEGORY_OPENABLE)
            intent.type = "*/*"
            intent.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
        }
        pending = result
        cancellation = AtomicBoolean(false)
        try {
            host.startActivityForResult(intent, REQUEST_CODE)
        } catch (_: Exception) {
            pending = null
            result.error("unavailable", "Could not open the file picker", null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_CODE) return false
        val reply = pending ?: return true
        if (resultCode != Activity.RESULT_OK || data == null) {
            pending = null
            reply.success(null)
            return true
        }
        val uris = data.clipData?.let { clips -> (0 until clips.itemCount).map { clips.getItemAt(it).uri } }
            ?: listOfNotNull(data.data)
        val folder = folderMode
        val cancelled = cancellation
        worker.execute {
            try {
                val items = copySelection(uris, folder, cancelled)
                main.post {
                    if (pending === reply) {
                        pending = null
                        reply.success(items)
                    }
                }
            } catch (_: Exception) {
                main.post {
                    if (pending === reply) {
                        pending = null
                        reply.error("import_failed", "Could not import music. Check file access and available storage.", null)
                    }
                }
            }
        }
        return true
    }

    private data class Document(val uri: Uri, val name: String, val directory: Boolean)
    private data class Selected(val document: Document, val relative: String, val parent: String)

    private fun document(uri: Uri): Document {
        val resolver = context.contentResolver
        resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) return Document(uri, cursor.getString(0) ?: "Audio", resolver.getType(uri) == DocumentsContract.Document.MIME_TYPE_DIR)
        }
        throw IllegalArgumentException("Document is unavailable")
    }

    private fun safeName(name: String): String {
        val safe = name.map { if (it == '/' || it == '\\' || it.code < 32) '_' else it }.joinToString("")
        return if (safe.isBlank() || safe == "." || safe == "..") "Audio" else safe
    }

    private fun children(tree: Uri, directory: Document): List<Document> {
        val id = DocumentsContract.getDocumentId(directory.uri)
        val uri = DocumentsContract.buildChildDocumentsUriUsingTree(tree, id)
        val columns = arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME, DocumentsContract.Document.COLUMN_MIME_TYPE)
        val result = mutableListOf<Document>()
        val cursor = context.contentResolver.query(uri, columns, null, null, null)
            ?: throw IllegalArgumentException("Folder is unavailable")
        cursor.use {
            while (it.moveToNext()) {
                val name = it.getString(1) ?: "Audio"
                if (!name.startsWith(".")) result.add(Document(DocumentsContract.buildDocumentUriUsingTree(tree, it.getString(0)), name, it.getString(2) == DocumentsContract.Document.MIME_TYPE_DIR))
            }
        }
        return result.sortedBy { it.name.lowercase() }
    }

    private fun copySelection(uris: List<Uri>, folder: Boolean, cancelled: AtomicBoolean): List<Map<String, Any>> {
        val batch = UUID.randomUUID().toString()
        val base = File(context.filesDir, "local_music/$batch")
        check(base.mkdirs())
        val items = mutableListOf<Map<String, Any>>()
        val visited = mutableSetOf<Uri>()
        try {
            for ((index, selection) in uris.withIndex()) {
                val root = if (folder) document(DocumentsContract.buildDocumentUriUsingTree(selection, DocumentsContract.getTreeDocumentId(selection))) else document(selection)
                val stack = ArrayDeque<Selected>()
                stack.add(Selected(root, if (folder) safeName(root.name) else "$index/${safeName(root.name)}", "local:root"))
                while (stack.isNotEmpty()) {
                    check(!cancelled.get())
                    val selected = stack.removeLast()
                    val source = selected.document
                    if (!visited.add(source.uri)) continue
                    val destination = File(base, selected.relative)
                    check(destination.canonicalPath.startsWith(base.canonicalPath + File.separator))
                    val id = "local:$batch:${selected.relative}"
                    val node = mutableMapOf<String, Any>(
                        "id" to id, "name" to source.name,
                        "kind" to if (source.directory) "folder" else "track",
                        "parentId" to selected.parent, "fileName" to if (source.directory) "" else source.name,
                        "path" to "local_music/$batch/${selected.relative}")
                    if (source.directory) {
                        check(destination.mkdirs())
                        items.add(node)
                        val used = mutableSetOf<String>()
                        for (child in children(selection, source).asReversed()) {
                            val name = safeName(child.name)
                            var unique = name
                            var suffix = 1
                            while (!used.add(unique)) unique = "${suffix++}-$name"
                            stack.add(Selected(child, "${selected.relative}/$unique", id))
                        }
                    } else if (source.name.substringAfterLast('.', "").lowercase() in FORMATS) {
                        destination.parentFile?.mkdirs()
                        val input = context.contentResolver.openInputStream(source.uri)
                            ?: throw IllegalArgumentException("File is unavailable")
                        input.use { stream ->
                            destination.outputStream().use { output ->
                                val buffer = ByteArray(64 * 1024)
                                while (true) {
                                    check(!cancelled.get())
                                    val count = stream.read(buffer)
                                    if (count < 0) break
                                    output.write(buffer, 0, count)
                                }
                            }
                        }
                        node["name"] = ""
                        val metadata = MediaMetadataRetriever()
                        try {
                            metadata.setDataSource(destination.path)
                            metadata.extractMetadata(MediaMetadataRetriever.METADATA_KEY_TITLE)?.let { node["name"] = it }
                            metadata.extractMetadata(MediaMetadataRetriever.METADATA_KEY_ARTIST)?.let { node["artist"] = it }
                            metadata.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull()?.let { node["durationMs"] = it }
                        } catch (_: RuntimeException) {
                            // Unsupported tags do not prevent filename-based playback.
                        } finally {
                            metadata.release()
                        }
                        items.add(node)
                    }
                }
            }
            check(!cancelled.get())
            return items
        } catch (error: Exception) {
            base.deleteRecursively()
            throw error
        }
    }

    companion object {
        private const val REQUEST_CODE = 7301
        private val FORMATS = setOf("mp3", "m4a", "flac", "wav", "aac", "aiff", "aif", "alac", "caf", "mp4", "ogg", "opus")
    }
}
