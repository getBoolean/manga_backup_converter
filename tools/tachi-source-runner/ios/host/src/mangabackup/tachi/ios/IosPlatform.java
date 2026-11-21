package mangabackup.tachi.ios;

import java.io.File;
import java.io.IOException;
import java.io.UncheckedIOException;
import mangabackup.tachi.protocol.ArtifactRewrite;
import mangabackup.tachi.protocol.DeadlineTimer;
import mangabackup.tachi.protocol.OperationGuard;
import mangabackup.tachi.protocol.PausableDeadline;
import mangabackup.tachi.protocol.WorkerPlatform;

/**
 * The shared worker's iOS platform hooks (U9; KTD11, KTD12).
 *
 * <ul>
 *   <li>Every operation runs under a native deadline armed with the
 *       dispatcher's watchdog, so the operation stops at its next rewritten
 *       back-edge and its host waits end even if Dart never sends
 *       {@code cancel}. Between {@code interaction.started} and
 *       {@code interaction.ended} (protocol 1.3) the deadline is paused, and
 *       resumes with the budget that remained.</li>
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
        return new PausableDeadline(deadlineMillis, new NativeTimer(worker, thread, onExpire), System::nanoTime);
    }

    /**
     * The dispatcher's native watchdog as a {@link DeadlineTimer}. Each arm is a new native token, so an
     * interaction pause (protocol 1.3) disarms the running token and the resume arms a fresh one for the
     * budget that remained; {@link PausableDeadline} does the accounting and serialises the calls.
     */
    private static final class NativeTimer implements DeadlineTimer {
        private final long worker;
        private final Thread thread;
        private final Runnable onExpire;
        private long token;
        private boolean armed;

        NativeTimer(long worker, Thread thread, Runnable onExpire) {
            this.worker = worker;
            this.thread = thread;
            this.onExpire = onExpire;
        }

        @Override
        public void arm(long ms) {
            token = IosNatives.arm(worker, thread, ms);
            IosNatives.onFire(token, onExpire);
            armed = true;
        }

        @Override
        public boolean disarm() {
            if (!armed) return false;
            armed = false;
            boolean fired = IosNatives.disarm(token);
            IosNatives.forget(token);
            return fired;
        }

        @Override
        public void fireNow() {
            if (armed) IosNatives.expireNow(token);
        }
    }
}
