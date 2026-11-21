package androidx.webkit;

/**
 * androidx.webkit.WebViewFeature for the desktop host (KTD20). Only {@link #DOCUMENT_START_SCRIPT} is
 * reported supported: it maps to the browser port's page-start scripts. Whether the session's engine
 * actually has them is known only once the session opens; if it does not, the call fails with a named
 * {@code capability-unavailable} error rather than being skipped. Every other feature is unsupported.
 */
public final class WebViewFeature {
    public static final String DOCUMENT_START_SCRIPT = "DOCUMENT_START_SCRIPT";
    public static final String WEB_MESSAGE_LISTENER = "WEB_MESSAGE_LISTENER";
    public static final String USER_AGENT_METADATA = "USER_AGENT_METADATA";

    private WebViewFeature() { }

    public static boolean isFeatureSupported(String feature) {
        return DOCUMENT_START_SCRIPT.equals(feature);
    }
}
