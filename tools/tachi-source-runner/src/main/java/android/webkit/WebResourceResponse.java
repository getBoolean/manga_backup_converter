package android.webkit;

import java.io.InputStream;
import java.util.Map;

public class WebResourceResponse {
    private String mimeType;
    private String encoding;
    private int statusCode = 200;
    private String reasonPhrase = "OK";
    private Map<String, String> responseHeaders;
    private InputStream data;

    public WebResourceResponse(String mimeType, String encoding, InputStream data) {
        this.mimeType = mimeType;
        this.encoding = encoding;
        this.data = data;
    }

    public WebResourceResponse(String mimeType, String encoding, int statusCode, String reasonPhrase,
                               Map<String, String> responseHeaders, InputStream data) {
        this(mimeType, encoding, data);
        this.statusCode = statusCode;
        this.reasonPhrase = reasonPhrase;
        this.responseHeaders = responseHeaders;
    }

    public String getMimeType() { return mimeType; }
    public void setMimeType(String m) { mimeType = m; }
    public String getEncoding() { return encoding; }
    public void setEncoding(String e) { encoding = e; }
    public int getStatusCode() { return statusCode; }
    public String getReasonPhrase() { return reasonPhrase; }
    public void setStatusCodeAndReasonPhrase(int code, String reason) { statusCode = code; reasonPhrase = reason; }
    public Map<String, String> getResponseHeaders() { return responseHeaders; }
    public void setResponseHeaders(Map<String, String> h) { responseHeaders = h; }
    public InputStream getData() { return data; }
    public void setData(InputStream d) { data = d; }
}

