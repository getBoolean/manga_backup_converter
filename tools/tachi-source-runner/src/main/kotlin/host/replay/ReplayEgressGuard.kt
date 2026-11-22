package mangabackup.tachi.host.replay

import java.io.File
import java.io.IOException
import java.net.InetAddress
import java.net.Proxy
import java.net.ProxySelector
import java.net.ServerSocket
import java.net.SocketAddress
import java.net.URI
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread

/**
 * Replay mode's backstop for traffic that does not go through the worker's
 * OkHttp clients (L3): `HttpURLConnection`, `java.net.http`, `URL.openStream`
 * and raw `java.net.Socket`s all consult the default [ProxySelector] (raw
 * sockets for `socket://` URIs, through the JDK's SOCKS socket
 * implementation). The guard answers every non-loopback destination with a
 * proxy on loopback that accepts and immediately closes each connection, so
 * the request fails without a packet leaving the machine and without falling
 * back to a direct connection (the JDK only connects directly when the
 * selector returns [Proxy.NO_PROXY]). Loopback destinations stay direct: the
 * replay servers live there.
 *
 * [emptyHostsFile] additionally points `jdk.net.hosts.file` at an empty file,
 * so a host name looked up outside OkHttp's replay DNS resolves to nothing
 * instead of sending a DNS query. The JDK reads that property once, when
 * name resolution first initialises, so it must be set before anything
 * resolves a name ([install] is called first thing in replay mode).
 */
class ReplayEgressGuard private constructor(private val server: ServerSocket) : AutoCloseable {
    private val refusedCount = AtomicInteger()

    /** Connections the refusing proxy received (each one a blocked egress attempt). */
    val refused: Int get() = refusedCount.get()

    val selector: ProxySelector = object : ProxySelector() {
        override fun select(uri: URI): List<Proxy> {
            val host = uri.host
            if (host != null && isLoopbackLiteral(host)) return listOf(Proxy.NO_PROXY)
            val type = if (uri.scheme.equals("socket", ignoreCase = true)) Proxy.Type.SOCKS else Proxy.Type.HTTP
            return listOf(Proxy(type, server.localSocketAddress))
        }

        override fun connectFailed(uri: URI, sa: SocketAddress, ioe: IOException) = Unit
    }

    private val acceptor = thread(name = "replay-egress-guard", isDaemon = true) {
        while (!server.isClosed) {
            try {
                server.accept().use { refusedCount.incrementAndGet() }
            } catch (_: IOException) {
                // Closed.
            }
        }
    }

    override fun close() {
        server.close()
        acceptor.join(1000)
    }

    companion object {
        /**
         * Starts a guard and makes it the process's default [ProxySelector]
         * (and, with [hostsFile], the JDK's hosts file). Returns the guard;
         * the previous selector is not restored (replay is for the process).
         */
        fun install(hostsFile: File? = null): ReplayEgressGuard {
            if (hostsFile != null) System.setProperty("jdk.net.hosts.file", hostsFile.absolutePath)
            val guard = start()
            ProxySelector.setDefault(guard.selector)
            return guard
        }

        /** A guard that is not installed (tests install its [selector] themselves). */
        fun start(): ReplayEgressGuard =
            ReplayEgressGuard(ServerSocket(0, 50, InetAddress.getLoopbackAddress()))

        /** An empty hosts file in [dir], for [install]. */
        fun emptyHostsFile(dir: File): File = File(dir, "replay-hosts").apply {
            parentFile.mkdirs()
            writeText("")
        }

        /** Literal loopback hosts only: deciding must not itself resolve a name. */
        fun isLoopbackLiteral(host: String): Boolean {
            val h = host.removePrefix("[").removeSuffix("]").lowercase()
            return h == "localhost" || h.startsWith("127.") || h == "::1" || h == "0:0:0:0:0:0:0:1"
        }
    }
}
