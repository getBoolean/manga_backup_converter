package mangabackup.tachi.shim;

import android.webkit.ValueCallback;
import android.webkit.WebView;
import androidx.webkit.ScriptHandler;
import java.util.Map;
import java.util.Set;

/**
 * What {@link WebView} forwards to. The worker's KTD20 translation layer
 * implements it over {@code host.browser.*} reverse requests. Every call is
 * made on the worker-owned main looper and must not block it.
 */
public interface WebViewBackend {
    interface Factory {
        WebViewBackend create(WebView view);
    }

    void loadUrl(String url, Map<String, String> headers);

    void loadDataWithBaseUrl(String baseUrl, String data, String mimeType, String encoding, String historyUrl);

    void evaluateJavascript(String script, ValueCallback<String> callback);

    void addJavascriptInterface(Object target, String name);

    void removeJavascriptInterface(String name);

    /** androidx.webkit.WebViewCompat.addDocumentStartJavaScript. */
    ScriptHandler addDocumentStartJavaScript(String script, Set<String> allowedOriginRules);

    void setUserAgent(String userAgent);

    /**
     * Shows the session's window so the user can solve a challenge or log in ({@code host.browser.show}).
     * Not an Android API: on Android a WebView becomes visible by being attached to a window, which
     * extensions here never do, so host code reaches this through {@link WebView#hostBackend()}.
     *
     * <p>The show ends (protocol 1.3) when the user closes the window ({@code "closed"}), or when the
     * extension signals completion ({@code "completed"}): a page message arrives on one of
     * {@code completionChannels} (channels installed with {@code addJavascriptInterface}), or
     * {@link #endInteraction()} is called. {@code onOutcome} receives the outcome on the main looper.
     * When the interaction bound elapses the operation's failure is {@code interaction-required} and
     * {@code WebViewClient.onReceivedError} is called instead. Later calls on this WebView do not wait
     * for the interaction to end.
     */
    void showForInteraction(Set<String> completionChannels, ValueCallback<String> onOutcome);

    /**
     * Signals that the pending interaction is complete ({@code host.browser.endInteraction}, protocol 1.3).
     * Callable from any thread; it never waits. Does nothing when no show is pending.
     */
    void endInteraction();

    void stopLoading();

    void destroy();

    String getUrl();
}

