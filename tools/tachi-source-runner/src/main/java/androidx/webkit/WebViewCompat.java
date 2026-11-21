package androidx.webkit;

import android.webkit.WebView;
import java.util.Set;

/** androidx.webkit.WebViewCompat: the members the desktop host translates (KTD20). */
public final class WebViewCompat {
    private WebViewCompat() { }

    /**
     * Registers {@code script} to run at document start in every later document whose frame origin
     * matches {@code allowedOriginRules} (androidx rule grammar: {@code *}, or
     * {@code scheme://host[:port]} with an optional leading {@code *.} subdomain wildcard). Forwarded
     * to {@code host.browser.addPageStartScript}; the origin rules are enforced by a
     * {@code location.origin} check wrapped around the script.
     */
    public static ScriptHandler addDocumentStartJavaScript(WebView webView, String script, Set<String> allowedOriginRules) {
        return webView.hostBackend().addDocumentStartJavaScript(script, allowedOriginRules);
    }
}
