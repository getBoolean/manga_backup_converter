package gate.ext;

import gate.host.HostLib;
import gate.host.HostNatives;
import java.util.regex.Pattern;

/**
 * Extension-side entry points for the U16 iOS runtime gate. Every entry point
 * is {@code static String name(String arg)} so the dispatcher can call it
 * without per-method JNI glue. Loops are bounded so a mechanism that fails to
 * interrupt still lets the measurement finish.
 */
public final class GateExtension {
    private GateExtension() {}

    public static String hello(String arg) {
        return "hello " + arg
                + " java.version=" + System.getProperty("java.version")
                + " java.vm.name=" + System.getProperty("java.vm.name")
                + " java.vm.info=" + System.getProperty("java.vm.info")
                + " os.name=" + System.getProperty("os.name")
                + " os.arch=" + System.getProperty("os.arch")
                + " java.home=" + System.getProperty("java.home");
    }

    /** Call-free counting loop; returns iterations and elapsed nanoseconds. */
    public static String spin(String arg) {
        long limit = Long.parseLong(arg);
        long start = System.nanoTime();
        long n = 0;
        long x = 7;
        while (n < limit) {
            x = x * 6364136223846793005L + 1442695040888963407L;
            n++;
        }
        long elapsed = System.nanoTime() - start;
        return "iterations=" + n + " elapsedNs=" + elapsed + " x=" + (x & 0xff);
    }

    /** Extension loop that spends its time inside the host library. */
    public static String hostLoop(String arg) {
        long rounds = Long.parseLong(arg);
        long h = HostLib.scan("the quick brown fox jumps over the lazy dog", rounds);
        return "hash=" + h;
    }

    /**
     * Catastrophic backtracking inside java.util.regex. The backreference
     * defeats the greedy-loop memoization that makes patterns such as
     * {@code (x+x+)+y} linear in current JDKs.
     */
    public static String regex(String arg) {
        int n = Integer.parseInt(arg);
        String input = "x".repeat(n);
        boolean matched = Pattern.compile("((x+)\\2?)+y").matcher(input).matches();
        return "matched=" + matched + " n=" + n;
    }

    /** Swallows every Throwable and keeps looping. */
    public static String catchAll(String arg) {
        long rounds = Long.parseLong(arg);
        long caught = 0;
        long x = 3;
        for (long r = 0; r < rounds; r++) {
            try {
                for (int i = 0; i < 100_000; i++) {
                    x = x * 6364136223846793005L + 1442695040888963407L;
                }
            } catch (Throwable t) {
                caught++;
            }
        }
        return "completed caught=" + caught + " x=" + (x & 0xff);
    }

    /** Blocks in a native host wait. */
    public static String nativeWait(String arg) {
        boolean cancelled = HostNatives.await(Long.parseLong(arg));
        return "cancelled=" + cancelled;
    }

    /** Requests a full GC and reports how long the request took. */
    public static String gc(String arg) {
        long start = System.nanoTime();
        System.gc();
        return "gcNs=" + (System.nanoTime() - start);
    }
}
