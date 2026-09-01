package im.cridland.wimsy

import android.net.DnsResolver
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors
import kotlin.math.min

class MainActivity : FlutterActivity() {
    private val channelName = "wimsy/dns"
    private val loginLinkChannelName = "wimsy/login_link"
    private val displayMetricsChannelName = "wimsy/display_metrics"
    private var loginLinkChannel: MethodChannel? = null
    private var pendingLoginLink: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        pendingLoginLink = intent?.dataString
        loginLinkChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            loginLinkChannelName
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                if (call.method == "getInitialLink") {
                    result.success(pendingLoginLink)
                    pendingLoginLink = null
                } else {
                    result.notImplemented()
                }
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            displayMetricsChannelName
        ).setMethodCallHandler { call, result ->
            if (call.method != "getPhysicalHeightInches") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val metrics = resources.displayMetrics
            if (metrics.ydpi <= 0f) {
                result.success(null)
            } else {
                result.success(metrics.heightPixels.toDouble() / metrics.ydpi.toDouble())
            }
        }
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        channel.setMethodCallHandler { call, result ->
            if (call.method != "resolveSrv") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val name = call.argument<String>("name") ?: ""
            if (name.isEmpty()) {
                result.success(emptyList<Map<String, Any>>())
                return@setMethodCallHandler
            }
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                result.success(emptyList<Map<String, Any>>())
                return@setMethodCallHandler
            }
            querySrv(name, result)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val link = intent.dataString ?: return
        loginLinkChannel?.invokeMethod("onLoginLink", link)
    }

    private fun querySrv(name: String, result: MethodChannel.Result) {
        val executor = Executors.newSingleThreadExecutor()
        val resolver = DnsResolver.getInstance()
        val handler = Handler(Looper.getMainLooper())
        val queryId = (Math.random() * 0xFFFF).toInt()
        val query = buildSrvQuery(name, queryId)
        resolver.rawQuery(
            null,
            query,
            DnsResolver.FLAG_EMPTY,
            executor,
            null,
            object : DnsResolver.Callback<ByteArray> {
                override fun onAnswer(answer: ByteArray, rcode: Int) {
                    val records = parseSrvResponse(answer, queryId)
                    handler.post { result.success(records) }
                    executor.shutdown()
                }

                override fun onError(error: DnsResolver.DnsException) {
                    handler.post { result.success(emptyList<Map<String, Any>>()) }
                    executor.shutdown()
                }
            }
        )
    }

    private fun buildSrvQuery(name: String, id: Int): ByteArray {
        val out = ByteArrayOutputStream()
        out.write(byteArrayOf(((id shr 8) and 0xFF).toByte(), (id and 0xFF).toByte()))
        out.write(byteArrayOf(0x01, 0x00))
        out.write(byteArrayOf(0x00, 0x01))
        out.write(byteArrayOf(0x00, 0x00))
        out.write(byteArrayOf(0x00, 0x00))
        out.write(byteArrayOf(0x00, 0x00))
        out.write(encodeName(name))
        out.write(byteArrayOf(0x00, 0x21))
        out.write(byteArrayOf(0x00, 0x01))
        return out.toByteArray()
    }

    private fun encodeName(name: String): ByteArray {
        val out = ByteArrayOutputStream()
        val labels = name.split(".")
        for (label in labels) {
            val bytes = label.toByteArray(Charsets.UTF_8)
            out.write(byteArrayOf(bytes.size.toByte()))
            out.write(bytes)
        }
        out.write(0)
        return out.toByteArray()
    }

    private fun parseSrvResponse(data: ByteArray, expectedId: Int): List<Map<String, Any>> {
        if (data.size < 12) {
            return emptyList()
        }
        val responseId = ((data[0].toInt() and 0xFF) shl 8) or (data[1].toInt() and 0xFF)
        if (responseId != expectedId) {
            return emptyList()
        }
        val qdCount = readUInt16(data, 4)
        val anCount = readUInt16(data, 6)
        var offset = 12
        repeat(qdCount) {
            offset = skipName(data, offset)
            offset += 4
            if (offset > data.size) {
                return emptyList()
            }
        }
        val records = mutableListOf<Map<String, Any>>()
        repeat(anCount) {
            offset = skipName(data, offset)
            if (offset + 10 > data.size) {
                return records
            }
            val type = readUInt16(data, offset)
            offset += 2
            offset += 2
            offset += 4
            val rdLength = readUInt16(data, offset)
            offset += 2
            if (offset + rdLength > data.size) {
                return records
            }
            if (type == 33 && rdLength >= 7) {
                val priority = readUInt16(data, offset)
                val weight = readUInt16(data, offset + 2)
                val port = readUInt16(data, offset + 4)
                val nameResult = readName(data, offset + 6)
                val host = nameResult.first.trimEnd('.')
                if (host.isNotEmpty()) {
                    records.add(
                        mapOf(
                            "host" to host,
                            "port" to port,
                            "priority" to priority,
                            "weight" to weight
                        )
                    )
                }
            }
            offset += rdLength
        }
        return records
    }

    private fun readUInt16(data: ByteArray, offset: Int): Int {
        if (offset + 1 >= data.size) {
            return 0
        }
        return ((data[offset].toInt() and 0xFF) shl 8) or (data[offset + 1].toInt() and 0xFF)
    }

    private fun skipName(data: ByteArray, offset: Int): Int {
        var current = offset
        while (current < data.size) {
            val length = data[current].toInt() and 0xFF
            if (length == 0) {
                return current + 1
            }
            if (length and 0xC0 == 0xC0) {
                return min(current + 2, data.size)
            }
            current += length + 1
        }
        return data.size
    }

    private fun readName(data: ByteArray, offset: Int): Pair<String, Int> {
        val labels = mutableListOf<String>()
        var current = offset
        var jumped = false
        var jumpOffset = 0
        while (current < data.size) {
            val length = data[current].toInt() and 0xFF
            if (length == 0) {
                current += 1
                break
            }
            if (length and 0xC0 == 0xC0) {
                val pointer = ((length and 0x3F) shl 8) or (data[current + 1].toInt() and 0xFF)
                if (!jumped) {
                    jumpOffset = current + 2
                }
                current = pointer
                jumped = true
                continue
            }
            val end = current + 1 + length
            if (end > data.size) {
                break
            }
            val label = String(data, current + 1, length, Charsets.UTF_8)
            labels.add(label)
            current = end
        }
        val name = labels.joinToString(".")
        val nextOffset = if (jumped) jumpOffset else current
        return Pair(name, nextOffset)
    }
}
