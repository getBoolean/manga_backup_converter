package mangabackup.tachi.host

import android.content.Context
import android.content.SharedPreferences
import eu.kanade.tachiyomi.network.NetworkHelper
import mangabackup.tachi.shim.UnsupportedHostApi
import okhttp3.Call
import okhttp3.Dispatcher
import okhttp3.EventListener
import okhttp3.OkHttpClient
import java.io.File
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.SynchronousQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/** Configures the transport of every base OkHttp client (live, replay or record). */
fun interface HostTransport {
    fun configure(builder: OkHttpClient.Builder)

    companion object {
        val LIVE = HostTransport { }
    }
}

/** Implemented by the class loader of a loaded package so stack frames identify their package. */
interface PackageOwned {
    val environment: PackageEnvironment
}

/** What the worker needs to know about an operation that is running for a package. */
interface OperationContext {
    /** Request ID of the in-flight `req`; reverse requests name it in `of`. */
    val requestId: String

    /** Records a host failure (browser capability, unsupported API) for error mapping. */
    fun recordHostFailure(failure: Throwable)

    val isCancelled: Boolean
}

/**
 * Everything one loaded package owns in the shared worker (KTD1, KTD9): its
 * Application/Context, in-memory preference stores, cookie jar, HTTP
 * dispatcher and state directory. Packages are not isolated from one another
 * beyond class-loader namespaces; this only keeps their state apart.
 */
class PackageEnvironment(
    val packageId: String,
    val stateDir: File,
    private val transport: HostTransport,
    val defaultUserAgent: String,
    settings: HostSettings,
) {
    val application: HostApplication = HostApplication(this)
    val cookieJar = PackageCookieJar()

    private val threadIds = AtomicInteger()
    private val executor: ExecutorService = ThreadPoolExecutor(0, Int.MAX_VALUE, 30, TimeUnit.SECONDS, SynchronousQueue()) { r ->
        Thread(r, "pkg-${packageId.substringAfterLast('.')}-http-${threadIds.incrementAndGet()}").apply { isDaemon = true }
    }
    private val dispatcher = Dispatcher(executor)
    private val activeCalls: MutableSet<Call> = ConcurrentHashMap.newKeySet()
    private val stores = ConcurrentHashMap<String, InMemorySharedPreferences>()

    @Volatile
    var settings: HostSettings = settings
        private set

    @Volatile
    var currentOperation: OperationContext? = null

    /** Set by the package loader; used for Context.getClassLoader. */
    @Volatile
    var classLoader: ClassLoader? = null

    val network: NetworkHelper by lazy { NetworkHelper(application) }

    @Volatile
    var closed = false
        private set

    private val callTracker = object : EventListener() {
        override fun callStart(call: Call) {
            activeCalls += call
            if (closed) call.cancel()
        }

        override fun callEnd(call: Call) {
            activeCalls -= call
        }

        override fun callFailed(call: Call, ioe: IOException) {
            activeCalls -= call
        }

        override fun canceled(call: Call) {
            activeCalls -= call
        }
    }

    fun newBaseClientBuilder(): OkHttpClient.Builder = OkHttpClient.Builder()
        .cookieJar(cookieJar)
        .dispatcher(dispatcher)
        .eventListener(callTracker)
        .also { transport.configure(it) }

    fun preferences(name: String): SharedPreferences {
        if (closed) throw IllegalStateException("package $packageId is closed")
        return stores.computeIfAbsent(name) { InMemorySharedPreferences(this.settings.seedFor(it)) }
    }

    /** Replaces the whole settings snapshot: every open store is re-seeded. */
    fun replaceSettings(newSettings: HostSettings) {
        settings = newSettings
        for ((name, store) in stores) store.reset(newSettings.seedFor(name))
    }

    /** Cancels every in-flight HTTP call of this package (cooperative cancellation). */
    fun cancelActiveCalls() {
        for (call in activeCalls.toList()) call.cancel()
    }

    fun activeCallCount(): Int = activeCalls.size

    fun close() {
        if (closed) return
        closed = true
        cancelActiveCalls()
        executor.shutdownNow()
        stores.clear()
        cookieJar.clear()
        stateDir.deleteRecursively()
    }

    companion object {
        /** The environment behind [context], or the calling package's. */
        fun of(context: Context?): PackageEnvironment {
            var c: Context? = context
            while (c != null) {
                if (c is HostApplication) return c.environment
                c = (c as? android.content.ContextWrapper)?.baseContext
            }
            return PackageScope.require("Context")
        }
    }
}

/** The Application each package receives (Injekt `Application`/`Context`). */
class HostApplication internal constructor(val environment: PackageEnvironment) : android.app.Application() {
    override fun getSharedPreferences(name: String, mode: Int): SharedPreferences = environment.preferences(name)

    override fun getPackageName(): String = environment.packageId

    override fun getCacheDir(): File = File(environment.stateDir, "cache").apply { mkdirs() }

    override fun getFilesDir(): File = File(environment.stateDir, "files").apply { mkdirs() }

    override fun getApplicationContext(): Context = this

    override fun getClassLoader(): ClassLoader =
        environment.classLoader ?: throw UnsupportedHostApi("Context.getClassLoader (package not loaded)")

    override fun getString(resId: Int): String = throw UnsupportedHostApi("Context.getString (Android resources)")
}

/**
 * Resolves the package a call belongs to. Extension code runs on worker, OkHttp
 * dispatcher, coroutine and main-looper threads alike, so the first stack frame
 * whose class came from a package class loader is authoritative; the
 * thread-bound package set by the worker around host-initiated calls is the
 * fallback.
 */
object PackageScope {
    private val walker: StackWalker = StackWalker.getInstance(StackWalker.Option.RETAIN_CLASS_REFERENCE)
    private val bound = ThreadLocal<PackageEnvironment?>()

    fun current(): PackageEnvironment? {
        val fromStack = walker.walk { frames ->
            frames.map { (it.declaringClass.classLoader as? PackageOwned)?.environment }
                .filter { it != null }
                .findFirst()
                .orElse(null)
        }
        return fromStack ?: bound.get()
    }

    fun require(what: String): PackageEnvironment =
        current() ?: throw IllegalStateException("$what requested outside any loaded package")

    fun <T> bind(environment: PackageEnvironment, block: () -> T): T {
        val previous = bound.get()
        bound.set(environment)
        try {
            return block()
        } finally {
            bound.set(previous)
        }
    }
}

