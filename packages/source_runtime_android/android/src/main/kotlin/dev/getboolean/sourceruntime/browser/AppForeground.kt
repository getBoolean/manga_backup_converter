package dev.getboolean.sourceruntime.browser

import android.app.Activity
import android.app.ActivityManager
import android.app.Application
import android.content.Context
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.Process
import androidx.annotation.Keep
import java.util.concurrent.ConcurrentHashMap

/** Foreground changes of [AppForegroundMonitor]; implemented in Dart as an asynchronous JNIgen listener. */
@Keep
interface AppForegroundListener {
    /** The app entered ([foreground] true) or left the foreground. */
    fun onForegroundChanged(foreground: Boolean)
}

/**
 * The app's one lifecycle signal (KTD18): the browser port's WebView host and
 * the Dart background gate both follow [ActivityTracker], so they cannot
 * disagree about whether the app is in the foreground. Listener calls only
 * post to Dart; nothing waits.
 */
@Keep
class AppForegroundMonitor(context: Context, private val listener: AppForegroundListener) {
    private val onChange: (Boolean) -> Unit = { listener.onForegroundChanged(it) }

    init {
        ActivityTracker.install(context.applicationContext, onChange)
    }

    /** Whether the app is in the foreground now. */
    fun isForeground(): Boolean = ActivityTracker.foreground

    /** Stops listening. */
    fun dispose() {
        ActivityTracker.remove(onChange)
    }
}

/**
 * Counts started Activities of this process (process-wide foreground state).
 *
 * Listeners hear "background" only after no Activity has been started for
 * [BACKGROUND_DELAY_MS], as `ProcessLifecycleOwner` does: an Activity
 * recreated for a configuration change, or one replacing another, stops
 * before its successor starts, and that gap is not the app leaving the
 * foreground.
 *
 * Another process of this app with a visible Activity (the `:source_runtime`
 * Cloudflare challenge, `ChallengeActivity`) keeps the app in the
 * foreground: while this process has none started, that is re-checked every
 * [BACKGROUND_DELAY_MS] until it ends or an Activity here starts again. A
 * bound service process only inherits its client's importance, so it counts
 * as visible only while it shows its own Activity.
 */
internal object ActivityTracker : Application.ActivityLifecycleCallbacks {
    @Volatile var started = 0
        private set

    /** Whether the app counts as in the foreground (what listeners last heard). */
    @Volatile var foreground = true
        private set

    private const val BACKGROUND_DELAY_MS = 700L
    private val main = Handler(Looper.getMainLooper())
    private var app: Context? = null
    private val checkBackground = object : Runnable {
        override fun run() {
            if (started > 0) return
            if (otherProcessVisible()) {
                main.postDelayed(this, BACKGROUND_DELAY_MS)
            } else {
                report(false)
            }
        }
    }

    private fun report(value: Boolean) {
        if (foreground == value) return
        foreground = value
        listeners.keys.forEach { it(value) }
    }

    @Volatile var top: Activity? = null
        private set

    private val listeners = ConcurrentHashMap<(Boolean) -> Unit, Boolean>()
    private var installed = false

    @Synchronized
    fun install(context: Context, onChange: (Boolean) -> Unit) {
        listeners[onChange] = true
        if (installed) return
        installed = true
        app = context.applicationContext
        (context.applicationContext as Application).registerActivityLifecycleCallbacks(this)
        // Activities started before the first listener existed.
        started = if (processVisible(context, Process.myPid())) 1 else 0
        foreground = started > 0
        if (!foreground) main.post(checkBackground)
    }

    fun remove(onChange: (Boolean) -> Unit) {
        listeners.remove(onChange)
    }

    private fun processVisible(context: Context, pid: Int): Boolean {
        val am = context.getSystemService(ActivityManager::class.java) ?: return false
        return am.runningAppProcesses.orEmpty().any {
            it.pid == pid && it.importance <= ActivityManager.RunningAppProcessInfo.IMPORTANCE_VISIBLE
        }
    }

    private fun otherProcessVisible(): Boolean {
        val context = app ?: return false
        val am = context.getSystemService(ActivityManager::class.java) ?: return false
        val me = Process.myPid()
        val uid = Process.myUid()
        return am.runningAppProcesses.orEmpty().any {
            it.pid != me && it.uid == uid && it.importance <= ActivityManager.RunningAppProcessInfo.IMPORTANCE_VISIBLE
        }
    }

    override fun onActivityStarted(activity: Activity) {
        started++
        main.removeCallbacks(checkBackground)
        report(true)
    }

    override fun onActivityStopped(activity: Activity) {
        started = (started - 1).coerceAtLeast(0)
        if (started == 0) {
            main.removeCallbacks(checkBackground)
            main.postDelayed(checkBackground, BACKGROUND_DELAY_MS)
        }
    }

    override fun onActivityResumed(activity: Activity) {
        top = activity
    }

    override fun onActivityPaused(activity: Activity) {
        if (top === activity) top = null
    }

    override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {}

    override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) {}

    override fun onActivityDestroyed(activity: Activity) {}
}
