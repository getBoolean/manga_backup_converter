package android.webkit;

public class WebChromeClient {
    public WebChromeClient() { }

    public boolean onConsoleMessage(ConsoleMessage consoleMessage) { return false; }

    public void onProgressChanged(WebView view, int newProgress) { }
}

