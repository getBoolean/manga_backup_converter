package eu.kanade.tachiyomi.network

import android.content.Context
import eu.kanade.tachiyomi.network.interceptor.CloudflareInterceptor
import eu.kanade.tachiyomi.network.interceptor.UncaughtExceptionInterceptor
import eu.kanade.tachiyomi.network.interceptor.UserAgentInterceptor
import mangabackup.tachi.host.PackageEnvironment
import okhttp3.CookieJar
import okhttp3.OkHttpClient
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Duration.Companion.seconds

/**
 * Per-package network service (extensions-lib `NetworkHelper`).
 *
 * The interceptor chain mirrors Mihon's (UncaughtException, UserAgent,
 * Cloudflare, by those simple names, which keiyoushi's `KeiSource` checks).
 * The cookie jar, dispatcher and transport come from the calling package's
 * [PackageEnvironment], so cookies never cross packages (KTD9). No disk cache is
 * configured: responses are not persisted.
 */
class NetworkHelper(context: Context) {
    private val environment: PackageEnvironment = PackageEnvironment.of(context)

    val cookieJar: CookieJar get() = environment.cookieJar

    val client: OkHttpClient by lazy {
        environment.newBaseClientBuilder()
            .connectTimeout(30.seconds)
            .readTimeout(30.seconds)
            .callTimeout(2.minutes)
            .addInterceptor(UncaughtExceptionInterceptor())
            .addInterceptor(UserAgentInterceptor(::defaultUserAgentProvider))
            .addInterceptor(CloudflareInterceptor())
            .build()
    }

    @Deprecated("The regular client handles Cloudflare by default")
    @Suppress("unused")
    val cloudflareClient: OkHttpClient get() = client

    fun defaultUserAgentProvider(): String = environment.defaultUserAgent
}

