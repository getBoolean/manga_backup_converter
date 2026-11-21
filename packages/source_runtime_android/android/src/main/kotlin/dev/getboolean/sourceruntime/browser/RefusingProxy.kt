package dev.getboolean.sourceruntime.browser

import java.net.InetAddress
import java.net.ServerSocket
import java.util.concurrent.CopyOnWriteArrayList

/**
 * Replay-mode proxy for the app-process WebView (tests only): accepts each
 * connection on 127.0.0.1, records its request line (`CONNECT host:443` or
 * `GET http://host/...`), and closes it without answering. With it set as
 * the WebView proxy and no DIRECT fallback, a request for any non-loopback
 * host fails in the engine; Chromium hands the host name to the proxy, so no
 * DNS lookup happens either. Never used on the production path.
 */
internal class RefusingProxy {
    private val socket = ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"))
    val port: Int get() = socket.localPort

    /** Request lines refused so far (the evidence that requests never left the device). */
    val refused = CopyOnWriteArrayList<String>()

    init {
        Thread({
            while (!socket.isClosed) {
                val client = runCatching { socket.accept() }.getOrNull() ?: break
                runCatching {
                    client.soTimeout = 2_000
                    val line = client.getInputStream().bufferedReader().readLine()
                    if (line != null) refused += line
                }
                runCatching { client.close() }
            }
        }, "srt-refusing-proxy").apply { isDaemon = true }.start()
    }
}
