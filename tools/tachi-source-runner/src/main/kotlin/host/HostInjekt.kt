package mangabackup.tachi.host

import android.app.Application
import android.content.Context
import dev.mihon.injekt.patchInjekt
import eu.kanade.tachiyomi.network.JavaScriptEngine
import eu.kanade.tachiyomi.network.NetworkHelper
import kotlinx.serialization.json.Json
import uy.kohesive.injekt.Injekt
import uy.kohesive.injekt.api.addFactory
import uy.kohesive.injekt.api.addSingleton

/**
 * Dependency injection for extensions (Injekt, as Mihon provides it).
 * Application, Context and NetworkHelper resolve to the calling package's
 * instances; Json matches Mihon's app configuration.
 */
object HostInjekt {
    @Volatile
    private var installed = false

    @Synchronized
    fun install() {
        if (installed) return
        patchInjekt()
        Injekt.addFactory<Application> { PackageScope.require("Application").application }
        Injekt.addFactory<Context> { PackageScope.require("Context").application }
        Injekt.addFactory<NetworkHelper> { PackageScope.require("NetworkHelper").network }
        Injekt.addFactory<JavaScriptEngine> { JavaScriptEngine(PackageScope.require("JavaScriptEngine").application) }
        Injekt.addSingleton<Json>(
            Json {
                ignoreUnknownKeys = true
                explicitNulls = false
            },
        )
        installed = true
    }
}
