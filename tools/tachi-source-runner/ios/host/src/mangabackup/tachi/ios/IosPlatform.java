package mangabackup.tachi.ios;

import java.io.File;
import java.io.IOException;
import java.io.UncheckedIOException;
import mangabackup.tachi.protocol.ArtifactRewrite;
import mangabackup.tachi.protocol.OperationGuard;
import mangabackup.tachi.protocol.WorkerPlatform;

/**
 * The shared worker's iOS platform hooks (U9; KTD11, KTD12).
 *
 * <ul>
 *   <li>Every operation runs under a native deadline armed with the
 *       dispatcher's watchdog, so the operation stops at its next rewritten
 *       back-edge and its host waits end even if Dart never sends
 *       {@code cancel}.</li>
 *   <li>Every prepared JAR, from either artifact path, goes through the
 *       back-edge rewrite pass after verification.</li>
 * </ul>
 */
final class IosPlatform implements WorkerPlatform {
    private final long worker;
    private final long deadlineMillis;
    private final ArtifactRewrite rewrite = new ArtifactRewrite() {
        @Override
        public String getVersion() {
            return BackedgeRewriter.VERSION;
        }

        @Override
        public void rewrite(File input, File output) {
            try {
                BackedgeRewriter.forExtensions().rewriteJar(input.toPath(), output.toPath(), IosPlatform.class.getClassLoader());
            } catch (IOException e) {
                throw new UncheckedIOException(e);
            }
        }
    };

    IosPlatform(long worker, long deadlineMillis) {
        this.worker = worker;
        this.deadlineMillis = deadlineMillis;
    }

    @Override
    public String getName() {
        return "ios";
    }

    @Override
    public Long pid() {
        return null;
    }

    @Override
    public ArtifactRewrite getArtifactRewrite() {
        return rewrite;
    }

    @Override
    public OperationGuard enterOperation(Thread thread, Runnable onExpire) {
        long token = IosNatives.arm(worker, thread, deadlineMillis);
        IosNatives.onFire(token, onExpire);
        return new Guard(token);
    }

    private static final class Guard implements OperationGuard {
        private final long token;
        private volatile boolean expired;
        private boolean closed;

        Guard(long token) {
            this.token = token;
        }

        @Override
        public boolean getExpired() {
            return expired;
        }

        @Override
        public void expireNow() {
            IosNatives.expireNow(token);
        }

        @Override
        public synchronized void close() {
            if (closed) return;
            closed = true;
            expired = IosNatives.disarm(token);
            IosNatives.forget(token);
        }
    }
}
