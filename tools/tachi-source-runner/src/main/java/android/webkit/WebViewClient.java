package android.webkit;

import android.graphics.Bitmap;

public class WebViewClient {
    public WebViewClient() { }

    public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
        return shouldOverrideUrlLoading(view, request.getUrl().toString());
    }

    @Deprecated
    public boolean shouldOverrideUrlLoading(WebView view, String url) { return false; }

    public void onPageStarted(WebView view, String url, Bitmap favicon) { }

    public void onPageFinished(WebView view, String url) { }

    public WebResourceResponse shouldInterceptRequest(WebView view, WebResourceRequest request) {
        return shouldInterceptRequest(view, request.getUrl().toString());
    }

    @Deprecated
    public WebResourceResponse shouldInterceptRequest(WebView view, String url) { return null; }

    public void onReceivedError(WebView view, WebResourceRequest request, WebResourceError error) {
        if (request.isForMainFrame()) {
            onReceivedError(view, error.getErrorCode(), String.valueOf(error.getDescription()), request.getUrl().toString());
        }
    }

    @Deprecated
    public void onReceivedError(WebView view, int errorCode, String description, String failingUrl) { }

    public void onReceivedHttpError(WebView view, WebResourceRequest request, WebResourceResponse errorResponse) { }

    public boolean onRenderProcessGone(WebView view, RenderProcessGoneDetail detail) { return false; }
}

