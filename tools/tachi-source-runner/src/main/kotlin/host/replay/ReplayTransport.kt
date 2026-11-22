package mangabackup.tachi.host.replay

import mangabackup.tachi.host.HostTransport
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.RecordedRequest
import okhttp3.Dns
import okhttp3.Headers
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import okio.Buffer
import java.io.File
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketAddress
import java.util.concurrent.CopyOnWriteArrayList
import javax.net.SocketFactory

/** Answers one HTTP exchange: replay from captures, or (capture tool only) forward and record. */
fun interface ExchangeHandler {
    fun handle(method: String, url: HttpUrl, headers: Headers, body: ByteArray): MockResponse
}

/**
 * Fail-closed loopback transport. Every host resolves to loopback and every
 * connection lands on a local MockWebServer (one plain, one TLS with a
 * throwaway certificate the worker's clients alone trust), so the source's
 * complete OkHttp chain — interceptors, signing, compression, rate limits —
 * runs unchanged while no packet leaves the machine. The handler sees the
 * final request exactly as the source sent it.
 */
open class LoopbackTransport(private val handler: ExchangeHandler) : HostTransport, AutoCloseable {
    private val loopback: InetAddress = InetAddress.getLoopbackAddress()
    private val root = HeldCertificate.Builder().certificateAuthority(0).commonName("tachi-source-runner replay CA").build()
    private val leaf = HeldCertificate.Builder().signedBy(root).commonName("replay").addSubjectAlternativeName("localhost").build()
    private val serverCerts = HandshakeCertificates.Builder().heldCertificate(leaf, root.certificate).build()
    private val clientCerts = HandshakeCertificates.Builder().addTrustedCertificate(root.certificate).build()

    private val plain = MockWebServer()
    private val tls = MockWebServer()

    init {
        plain.dispatcher = dispatcherFor("http")
        tls.dispatcher = dispatcherFor("https")
        tls.useHttps(serverCerts.sslSocketFactory())
        plain.start(loopback, 0)
        tls.start(loopback, 0)
    }

    private fun dispatcherFor(scheme: String) = object : Dispatcher() {
        override fun dispatch(request: RecordedRequest): MockResponse {
            val host = request.headers["Host"] ?: return MockResponse.Builder().code(400).body("no Host header").build()
            val url = "$scheme://$host${request.target}".toHttpUrl()
            return handler.handle(request.method, url, request.headers, request.body?.toByteArray() ?: ByteArray(0))
        }
    }

    private val socketFactory = object : SocketFactory() {
        private fun route(endpoint: SocketAddress): SocketAddress {
            val port = (endpoint as InetSocketAddress).port
            return InetSocketAddress(loopback, if (port == 80) plain.port else tls.port)
        }

        override fun createSocket(): Socket = object : Socket() {
            override fun connect(endpoint: SocketAddress, timeout: Int) = super.connect(route(endpoint), timeout)
        }

        override fun createSocket(host: String, port: Int): Socket = createSocket().apply { connect(InetSocketAddress(host, port)) }
        override fun createSocket(host: String, port: Int, localHost: InetAddress, localPort: Int): Socket = createSocket(host, port)
        override fun createSocket(host: InetAddress, port: Int): Socket = createSocket().apply { connect(InetSocketAddress(host, port)) }
        override fun createSocket(address: InetAddress, port: Int, localAddress: InetAddress, localPort: Int): Socket = createSocket(address, port)
    }

    override fun configure(builder: OkHttpClient.Builder) {
        builder
            .dns(Dns { listOf(loopback) })
            .socketFactory(socketFactory)
            .sslSocketFactory(clientCerts.sslSocketFactory(), clientCerts.trustManager)
            .hostnameVerifier { _, _ -> true }
            .protocols(listOf(Protocol.HTTP_1_1))
            .proxy(java.net.Proxy.NO_PROXY)
    }

    override fun close() {
        plain.close()
        tls.close()
    }
}

/** Requests a replay served or missed. */
class ReplayLog {
    val misses = CopyOnWriteArrayList<CaptureFormat.Key>()
    val served = CopyOnWriteArrayList<CaptureFormat.Key>()
}

/** Replays committed captures. A request with no capture gets a 599 and is recorded in [log]. */
class ReplayTransport private constructor(val captures: List<CaptureFormat.CaptureSet>, val log: ReplayLog) :
    LoopbackTransport(ExchangeHandler { method, url, _, body -> respond(captures, log, method, url, body) }) {

    companion object {
        const val MISS_STATUS = 599

        fun start(dirs: List<File>): ReplayTransport = ReplayTransport(dirs.map { CaptureFormat.load(it) }, ReplayLog())

        fun respond(captures: List<CaptureFormat.CaptureSet>, log: ReplayLog, method: String, url: HttpUrl, body: ByteArray): MockResponse {
            for (set in captures) {
                val key = CaptureFormat.key(method, url, body, set.manifest.volatileQueryParameters)
                val hit = set.lookup(key) ?: continue
                log.served += key
                val (exchange, bytes) = hit
                val builder = MockResponse.Builder().code(exchange.status).body(Buffer().write(bytes))
                for ((k, v) in exchange.headers) builder.setHeader(k, v)
                // One header per cookie: OkHttp reads each Set-Cookie line as a single cookie (Dart's
                // comma-joined form is a package:http artefact).
                for (c in exchange.setCookies) builder.addHeader("Set-Cookie", c.toHeader())
                return builder.build()
            }
            val key = CaptureFormat.key(method, url, body, emptySet())
            log.misses += key
            System.err.println("[replay] capture miss: $key")
            return MockResponse.Builder().code(MISS_STATUS).setHeader("content-type", "text/plain")
                .body("tachi-source-runner replay: no capture for $key").build()
        }
    }
}
