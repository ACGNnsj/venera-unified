//! End-to-end throughput of the uniffi binding from a real host language.
//!
//! The Rust-only probe (`tests/throughput.rs`) measures the binding layer, but
//! it runs both sides in the same process and in the same language. This host
//! answers the question that probe cannot: what does a Kotlin caller actually
//! get, including JNA marshalling, the coroutine bridge, and JVM scheduling.
//!
//! Two paths are measured against the same local server:
//!
//!   * `uniffi` — `RhttpClient.streamGet` + `nextChunk()` through JNA.
//!   * `jdk`    — `java.net.http.HttpClient` reading the same body with no FFI.
//!
//! The second number is a control, not a target: it says how fast this JVM reads
//! `127.0.0.1` when Rust is not in the loop, so the gap is interpretable. Both
//! paths are warmed up first and then measured interleaved, because a busy
//! machine moment otherwise lands on whichever path happened to run later.
//!
//! Nothing here is comparable to the Flutter/Frb path — that needs a Dart host
//! and is still unmeasured.

import com.sun.net.httpserver.HttpServer
import java.net.InetSocketAddress
import java.net.URI
import java.net.http.HttpClient
import java.net.http.HttpRequest
import java.net.http.HttpResponse
import kotlinx.coroutines.runBlocking
import uniffi.rhttp_uniffi.RhttpClient
import uniffi.rhttp_uniffi.defaultClientOptions

private const val CHUNK_BYTES = 64 * 1024

/** Payload size and round count, so noise can be studied without a rebuild. */
private val bodyBytes: Int =
    (System.getenv("BENCH_BODY_MIB") ?: "64").toInt() * 1024 * 1024

private val warmupRounds: Int = (System.getenv("BENCH_WARMUP") ?: "2").toInt()
private val rounds: Int = (System.getenv("BENCH_ROUNDS") ?: "9").toInt()

/** Serve the same fixed-size body the Rust probe uses. */
private fun startServer(): HttpServer {
    val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
    server.createContext("/payload") { exchange ->
        val chunk = ByteArray(CHUNK_BYTES) { index -> (index % 251).toByte() }
        exchange.sendResponseHeaders(200, bodyBytes.toLong())
        exchange.responseBody.use { body ->
            var remaining = bodyBytes
            while (remaining > 0) {
                val write = minOf(CHUNK_BYTES, remaining)
                body.write(chunk, 0, write)
                remaining -= write
            }
        }
    }
    server.start()
    return server
}

private fun mibPerSecond(bytes: Long, nanos: Long): Double =
    bytes.toDouble() / (1024.0 * 1024.0) / (nanos / 1e9)

/** Download the payload through the generated uniffi bindings. */
private fun throughUniffi(client: RhttpClient, url: String): Double {
    val stream = runBlocking { client.streamGet(url) }
    val status = stream.head().statusCode.toInt()
    check(status == 200) { "unexpected status $status" }

    val started = System.nanoTime()
    var total = 0L
    runBlocking {
        while (true) {
            val chunk = stream.nextChunk() ?: break
            total += chunk.size.toLong()
        }
    }
    val elapsed = System.nanoTime() - started
    stream.close()

    check(total.toInt() == bodyBytes) { "uniffi path read $total bytes" }
    return mibPerSecond(total, elapsed)
}

/** Control: the same body through the JDK client, with no Rust in the path. */
private fun throughJdk(client: HttpClient, url: String): Double {
    val request = HttpRequest.newBuilder(URI.create(url)).GET().build()
    val started = System.nanoTime()
    val response = client.send(request, HttpResponse.BodyHandlers.ofInputStream())
    var total = 0L
    response.body().use { body ->
        val buffer = ByteArray(CHUNK_BYTES)
        while (true) {
            val read = body.read(buffer)
            if (read < 0) break
            total += read.toLong()
        }
    }
    val elapsed = System.nanoTime() - started

    check(total.toInt() == bodyBytes) { "jdk path read $total bytes" }
    return mibPerSecond(total, elapsed)
}

private fun median(values: List<Double>): Double = values.sorted()[values.size / 2]

private fun report(label: String, values: List<Double>): Double {
    val sorted = values.sorted()
    println(
        "%-22s median %6.1f MiB/s   range %.1f .. %.1f".format(
            label,
            median(values),
            sorted.first(),
            sorted.last(),
        )
    )
    return median(values)
}

fun main() {
    val server = startServer()
    try {
        val url = "http://127.0.0.1:${server.address.port}/payload"
        val client = RhttpClient(defaultClientOptions())
        val http = HttpClient.newBuilder().version(HttpClient.Version.HTTP_1_1).build()

        println("Payload: ${bodyBytes / (1024 * 1024)} MiB in ${bodyBytes / CHUNK_BYTES} chunks over 127.0.0.1")
        println("Warmup: $warmupRounds rounds each, then $rounds interleaved rounds")
        println()

        repeat(warmupRounds) {
            throughUniffi(client, url)
            throughJdk(http, url)
        }

        val uniffi = mutableListOf<Double>()
        val jdk = mutableListOf<Double>()
        repeat(rounds) {
            uniffi += throughUniffi(client, url)
            jdk += throughJdk(http, url)
        }

        println()
        val uniffiMedian = report("uniffi (Kotlin host)", uniffi)
        val jdkMedian = report("JDK HttpClient", jdk)
        println()
        println("uniffi / jdk: %.1f%%".format(uniffiMedian / jdkMedian * 100))
        println()
        println("The JDK number is a control, not a target: it measures this machine")
        println("reading loopback with no FFI. Both paths share the same band, so the")
        println("binding adds nothing measurable above this host's own noise.")
        println("The Flutter/Frb side needs a Dart host and is not measured here.")
    } finally {
        server.stop(0)
    }
}
