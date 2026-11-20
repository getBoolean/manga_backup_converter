package gate.host;

/** Host services implemented by the native dispatcher (registered with RegisterNatives). */
public final class HostNatives {
    private HostNatives() {}

    /**
     * Blocks on a native latch owned by the current operation until it is
     * signalled, the operation is cancelled, or {@code millis} pass. Returns
     * true when the operation was cancelled (the dispatcher also throws the
     * deadline error in that case).
     */
    public static native boolean await(long millis);
}
