package gate.ext;

/**
 * Same call-free loop as {@link GateExtension#spin}, but excluded from the
 * rewrite pass. Stands in for any class-library code that was not rewritten.
 */
public final class Unrewritten {
    private Unrewritten() {}

    public static String spin(String arg) {
        long limit = Long.parseLong(arg);
        long start = System.nanoTime();
        long n = 0;
        long x = 7;
        while (n < limit) {
            x = x * 6364136223846793005L + 1442695040888963407L;
            n++;
        }
        return "iterations=" + n + " elapsedNs=" + (System.nanoTime() - start) + " x=" + (x & 0xff);
    }
}
