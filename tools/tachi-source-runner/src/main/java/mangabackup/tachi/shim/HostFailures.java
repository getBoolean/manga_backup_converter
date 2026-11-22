package mangabackup.tachi.shim;

import java.util.function.Consumer;

/**
 * Lets shims report a host-level failure (unsupported API, browser capability)
 * to the operation that is running, even when extension code later wraps or
 * swallows the exception. The worker installs the sink.
 */
public final class HostFailures {
    private static volatile Consumer<Throwable> sink = t -> { };

    private HostFailures() { }

    public static void install(Consumer<Throwable> newSink) {
        sink = newSink;
    }

    public static void record(Throwable failure) {
        sink.accept(failure);
    }
}

