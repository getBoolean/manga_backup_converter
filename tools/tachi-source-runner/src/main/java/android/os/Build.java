package android.os;

/** Reports a recent Android release so feature checks take modern code paths. */
public class Build {
    public static final String MANUFACTURER = "desktop";
    public static final String MODEL = "tachi-source-runner";
    public static final String BRAND = "desktop";
    public static final String DEVICE = "desktop";
    public static final String PRODUCT = "desktop";

    public static class VERSION {
        public static final int SDK_INT = 35;
        public static final String RELEASE = "15";
        public static final String CODENAME = "REL";
    }

    public static class VERSION_CODES {
        public static final int O = 26;
        public static final int P = 28;
        public static final int Q = 29;
        public static final int R = 30;
        public static final int S = 31;
        public static final int TIRAMISU = 33;
        public static final int UPSIDE_DOWN_CAKE = 34;
        public static final int VANILLA_ICE_CREAM = 35;
    }
}

