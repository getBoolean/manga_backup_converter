package mangabackup.tachi.shim;

/**
 * Thrown by a desktop-host shim for an Android API it deliberately does not
 * implement. Android SDK stub bodies are never treated as working
 * implementations: each unsupported member fails with its name so the worker
 * can report a named {@code capability-unavailable} error.
 */
public final class UnsupportedHostApi extends UnsupportedOperationException {
    private final String api;

    public UnsupportedHostApi(String api) {
        super("Unsupported Android API in the desktop Tachi host: " + api);
        this.api = api;
        HostFailures.record(this);
    }

    public String api() {
        return api;
    }
}

