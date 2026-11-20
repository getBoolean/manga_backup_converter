package android.webkit;

public abstract class WebResourceError {
    public WebResourceError() { }

    public abstract int getErrorCode();

    public abstract CharSequence getDescription();
}

