package androidx.webkit;

/** androidx.webkit.ScriptHandler: the handle {@link WebViewCompat#addDocumentStartJavaScript} returns. */
public interface ScriptHandler {
    /**
     * On Android, stops injecting the script into later documents. The desktop browser port has no
     * removal (protocol 1.2): page-start scripts last until the session closes, so the host's handler
     * throws {@link UnsupportedOperationException} (and adds an operation warning) instead of pretending
     * the script was removed.
     */
    void remove();
}
