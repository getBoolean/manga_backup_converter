package gate.host;

/**
 * Stands in for a parent-owned host library (for example jsoup) that
 * extension code calls into. Its loop is call-free, so only a back-edge
 * mechanism can stop it.
 */
public final class HostLib {
    private HostLib() {}

    /** Scans {@code text} {@code rounds} times with a call-free loop. */
    public static long scan(String text, long rounds) {
        final int n = text.length();
        final char[] chars = text.toCharArray();
        long h = 1125899906842597L;
        for (long r = 0; r < rounds; r++) {
            for (int i = 0; i < n; i++) {
                h = 31 * h + chars[i];
            }
        }
        return h;
    }
}
