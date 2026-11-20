// Extracted from Mihon (https://github.com/mihonapp/mihon) at f64d82b94218b42410c36e6c85da818574865a28,
// Apache License 2.0. Copyright the Mihon Open Source Project and Tachiyomi contributors.
// Changes for the desktop Tachi host are marked "desktop host:"; see THIRD_PARTY.md.

package eu.kanade.tachiyomi.source

import android.content.Context
import android.content.SharedPreferences
import androidx.preference.PreferenceScreen
import uy.kohesive.injekt.Injekt
import uy.kohesive.injekt.api.get

interface ConfigurableSource : Source {

    /**
     * Gets instance of [SharedPreferences] scoped to the specific source.
     *
     * @since extensions-lib 1.5
     */
    fun getSourcePreferences(): SharedPreferences =
        Injekt.get<Context>().getSharedPreferences(preferenceKey(), Context.MODE_PRIVATE)

    fun setupPreferenceScreen(screen: PreferenceScreen)
}

fun ConfigurableSource.preferenceKey(): String = "source_$id"

// TODO: use getSourcePreferences once all extensions are on ext-lib 1.5
fun ConfigurableSource.sourcePreferences(): SharedPreferences =
    Injekt.get<Context>().getSharedPreferences(preferenceKey(), Context.MODE_PRIVATE)

fun sourcePreferences(key: String): SharedPreferences =
    Injekt.get<Context>().getSharedPreferences(key, Context.MODE_PRIVATE)
