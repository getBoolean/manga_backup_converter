package mangabackup.tachi.ios;

import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Services implemented by the native dispatcher (`packages/source_runtime_ios/
 * src/source_runtime_ios.c`), bound with {@code RegisterNatives} when the VM
 * starts. No library is loaded: the image refuses JNI library loads from
 * anything but the class library (R18).
 */
public final class IosNatives {
    private IosNatives() {}

    /** Output streams of a worker channel. */
    public static final int STDOUT = 1;
    public static final int STDERR = 2;

    /** Blocks until bytes from Dart arrive for {@code worker}; -1 once its input is closed. */
    public static native int read(long worker, byte[] buffer, int offset, int length);

    /** Hands bytes to Dart (listener callback; never blocks on the Dart isolate). */
    public static native void write(long worker, int stream, byte[] buffer, int offset, int length);

    /**
     * Arms a native deadline for {@code thread}: when it passes, the
     * dispatcher's watchdog marks the thread expired for the rewritten
     * back-edge polls, interrupts it, and calls {@link #fired(long)}.
     * Returns a token for {@link #disarm(long)} and {@link #expireNow(long)}.
     */
    public static native long arm(long worker, Thread thread, long deadlineMillis);

    /** Fires the deadline now (a supervisor {@code cancel}). */
    public static native void expireNow(long token);

    /**
     * Disarms the deadline. When it returns the watchdog no longer touches
     * the thread, and any expired mark has been cleared. Returns whether the
     * deadline fired.
     */
    public static native boolean disarm(long token);

    private static final Map<Long, Runnable> ON_FIRE = new ConcurrentHashMap<>();
    private static final ExecutorService FIRED = Executors.newSingleThreadExecutor(r -> {
        Thread t = new Thread(r, "srt-deadline-actions");
        t.setDaemon(true);
        return t;
    });

    static void onFire(long token, Runnable action) {
        ON_FIRE.put(token, action);
    }

    static void forget(long token) {
        ON_FIRE.remove(token);
    }

    /**
     * Called by the native watchdog (on its own attached thread) after it
     * marked the thread expired. Must not block the watchdog: the cooperative
     * part (cancelling HTTP calls and browser waits) runs on a separate thread.
     */
    static void fired(long token) {
        Runnable action = ON_FIRE.remove(token);
        if (action != null) {
            FIRED.execute(action);
        }
    }
}
