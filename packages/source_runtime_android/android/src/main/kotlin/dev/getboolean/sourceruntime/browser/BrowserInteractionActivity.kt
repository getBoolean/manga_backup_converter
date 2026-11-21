package dev.getboolean.sourceruntime.browser

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.view.ViewGroup
import android.widget.Button
import android.widget.LinearLayout
import org.json.JSONObject

/**
 * Visible browser interaction of the app-process `BrowserPort` (KTD20,
 * protocol 1.3 show semantics): hosts one session's WebView while a user
 * solves a challenge.
 *
 * - The WebView belongs to the session, not to this Activity. It is created
 *   on a `MutableContextWrapper` over the application context; while shown,
 *   the wrapper's base is this Activity, and it returns to the application
 *   context when the Activity goes away. A configuration change recreates
 *   the Activity and the new instance re-attaches the same WebView, so page
 *   state, pending scripts and the show call survive (Activity detach and
 *   reattach).
 * - The show call ends exactly once: `closed` when the user leaves (close
 *   button, back, or the task removed), `hidden` when the port hides it
 *   (page-signalled completion, timeout or cancel, decided in Dart).
 * - Declared without `android:process`: it runs in the app process, beside
 *   the WebViews it shows.
 */
class BrowserInteractionActivity : Activity() {
    var sessionId: String? = null
        private set

    private var userClosed = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val pending = active
        val session = pending?.let { it.host.session(it.sessionId) }
        val view = session?.webView
        if (pending == null || session == null || view == null || pending.hidden) {
            finish()
            return
        }
        sessionId = pending.sessionId
        (view.parent as? ViewGroup)?.removeView(view)
        session.contextWrapper.baseContext = this
        val close = Button(this).apply {
            text = "Close"
            setOnClickListener { closeByUser() }
        }
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(close, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
            addView(view, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        }
        setContentView(root)
        current = this
        pending.host.event(pending.sessionId, "interaction", JSONObject().put("state", if (pending.shownOnce) "reattached" else "shown"))
        pending.shownOnce = true
    }

    @Deprecated("Back closes the interaction as the user")
    @Suppress("DEPRECATION")
    override fun onBackPressed() {
        closeByUser()
    }

    private fun closeByUser() {
        userClosed = true
        finish()
    }

    override fun onDestroy() {
        val pending = active
        val id = sessionId
        if (current === this) current = null
        if (pending != null && id != null && pending.sessionId == id) {
            val session = pending.host.session(id)
            session?.webView?.let { (it.parent as? ViewGroup)?.removeView(it) }
            session?.contextWrapper?.baseContext = applicationContext
            when {
                // A new instance re-attaches the WebView; the show goes on.
                isChangingConfigurations && !userClosed && !pending.hidden -> Unit
                pending.hidden -> end(pending, "hidden")
                else -> end(pending, "closed")
            }
        }
        super.onDestroy()
    }

    companion object {
        /** The interaction in progress (main looper only). */
        private var active: Active? = null

        @Volatile
        var current: BrowserInteractionActivity? = null
            private set

        private class Active(val host: AppBrowserHost, val sessionId: String, val callId: Long) {
            var hidden = false
            var shownOnce = false
        }

        internal fun show(host: AppBrowserHost, session: BrowserSessionView, callId: Long) {
            if (ActivityTracker.started == 0) {
                host.failReply(callId, "interaction", "The app has no visible Activity to show the browser in")
                return
            }
            if (active != null) {
                host.failReply(callId, "capability", "An interaction is already showing")
                return
            }
            active = Active(host, session.id, callId)
            val from = ActivityTracker.top
            val intent = Intent(from ?: session.contextWrapper.applicationContext, BrowserInteractionActivity::class.java)
            if (from == null) intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            (from ?: session.contextWrapper.applicationContext).startActivity(intent)
        }

        /** Ends the interaction of [sessionId] as hidden by the port. */
        fun hide(sessionId: String) {
            val pending = active ?: return
            if (pending.sessionId != sessionId) return
            pending.hidden = true
            val activity = current
            if (activity != null && activity.sessionId == sessionId) activity.finish() else end(pending, "hidden")
        }

        /** Test hook: recreates the shown Activity as a configuration change would. */
        fun recreateCurrent(): Boolean {
            val activity = current ?: return false
            activity.recreate()
            return true
        }

        /** Test hook: closes the shown Activity exactly as the user's close button does. */
        fun closeCurrentAsUser(): Boolean {
            val activity = current ?: return false
            activity.closeByUser()
            return true
        }

        private fun end(pending: Active, how: String) {
            if (active !== pending) return
            active = null
            pending.host.okReply(pending.callId, JSONObject().put("end", how))
        }
    }
}
