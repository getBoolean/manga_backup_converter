package android.util;

import java.nio.charset.StandardCharsets;

/**
 * Android's Base64 with its flag semantics: DEFAULT wraps encoded output at 76
 * columns with '\n' and ends with '\n'; decoding ignores whitespace and does not
 * require padding.
 */
public final class Base64 {
    public static final int DEFAULT = 0;
    public static final int NO_PADDING = 1;
    public static final int NO_WRAP = 2;
    public static final int CRLF = 4;
    public static final int URL_SAFE = 8;
    public static final int NO_CLOSE = 16;

    private Base64() { }

    public static byte[] decode(String str, int flags) {
        return decode(str.getBytes(StandardCharsets.US_ASCII), flags);
    }

    public static byte[] decode(byte[] input, int flags) {
        return decode(input, 0, input.length, flags);
    }

    public static byte[] decode(byte[] input, int offset, int len, int flags) {
        StringBuilder sb = new StringBuilder(len);
        for (int i = offset; i < offset + len; i++) {
            char c = (char) (input[i] & 0xff);
            if (c == '\n' || c == '\r' || c == ' ' || c == '\t') continue;
            if (c == '-') c = '+';
            else if (c == '_') c = '/';
            sb.append(c);
        }
        try {
            return java.util.Base64.getDecoder().decode(sb.toString());
        } catch (IllegalArgumentException e) {
            throw new IllegalArgumentException("bad base-64", e);
        }
    }

    public static String encodeToString(byte[] input, int flags) {
        return new String(encode(input, flags), StandardCharsets.US_ASCII);
    }

    public static String encodeToString(byte[] input, int offset, int len, int flags) {
        return new String(encode(input, offset, len, flags), StandardCharsets.US_ASCII);
    }

    public static byte[] encode(byte[] input, int flags) {
        return encode(input, 0, input.length, flags);
    }

    public static byte[] encode(byte[] input, int offset, int len, int flags) {
        byte[] slice = new byte[len];
        System.arraycopy(input, offset, slice, 0, len);
        java.util.Base64.Encoder encoder = (flags & URL_SAFE) != 0 ? java.util.Base64.getUrlEncoder() : java.util.Base64.getEncoder();
        if ((flags & NO_PADDING) != 0) encoder = encoder.withoutPadding();
        String encoded = encoder.encodeToString(slice);
        if ((flags & NO_WRAP) != 0) return encoded.getBytes(StandardCharsets.US_ASCII);
        String newline = (flags & CRLF) != 0 ? "\r\n" : "\n";
        StringBuilder out = new StringBuilder(encoded.length() + encoded.length() / 76 * 2 + 2);
        for (int i = 0; i < encoded.length(); i += 76) {
            out.append(encoded, i, Math.min(encoded.length(), i + 76)).append(newline);
        }
        return out.toString().getBytes(StandardCharsets.US_ASCII);
    }
}

