package mangabackup.tachi.host

import android.os.Handler
import android.os.Looper
import kotlinx.coroutines.InternalCoroutinesApi
import kotlinx.coroutines.MainCoroutineDispatcher
import kotlinx.coroutines.internal.MainDispatcherFactory
import kotlin.coroutines.CoroutineContext

/**
 * `Dispatchers.Main` for extension code, backed by the worker-owned main
 * looper (android.os.Looper.getMainLooper()). Registered through
 * META-INF/services so kotlinx.coroutines picks it up like the Android one.
 */
class LooperMainDispatcher(private val handler: Handler, private val immediateMode: Boolean) : MainCoroutineDispatcher() {
    override val immediate: MainCoroutineDispatcher by lazy {
        if (immediateMode) this else LooperMainDispatcher(handler, immediateMode = true)
    }

    override fun isDispatchNeeded(context: CoroutineContext): Boolean =
        !immediateMode || !handler.looper.isCurrentThread

    override fun dispatch(context: CoroutineContext, block: Runnable) {
        handler.post(block)
    }

    override fun toString(): String = if (immediateMode) "Dispatchers.Main.immediate[tachi-main]" else "Dispatchers.Main[tachi-main]"
}

@OptIn(InternalCoroutinesApi::class)
class LooperMainDispatcherFactory : MainDispatcherFactory {
    override val loadPriority: Int get() = Int.MAX_VALUE / 2

    override fun createDispatcher(allFactories: List<MainDispatcherFactory>): MainCoroutineDispatcher =
        LooperMainDispatcher(Handler(Looper.getMainLooper()), immediateMode = false)
}

