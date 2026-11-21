package mangabackup.tachi.ios;

import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.TimeUnit;
import mangabackup.tachi.host.HostTransport;
import mangabackup.tachi.host.SizingReport;
import mangabackup.tachi.host.replay.CaptureFormat;
import mangabackup.tachi.host.replay.LoopbackTransport;
import mangabackup.tachi.host.replay.ReplayLog;
import mangabackup.tachi.host.replay.ReplayTransport;
import mangabackup.tachi.protocol.Worker;
import mangabackup.tachi.protocol.WorkerOptions;
import mockwebserver3.MockResponse;

/**
 * Runs the shared Tachi worker inside the app's single embedded VM (U9).
 *
 * The native dispatcher calls {@link #run(long, String)} on a thread it owns
 * and attached to the VM. Protocol frames travel over a native channel instead
 * of a process's stdin/stdout: Dart writes bytes with
 * {@code srt_worker_write}, which {@link IosNatives#read} returns here, and
 * every frame the worker writes reaches Dart through a listener callback. The
 * worker itself is the desktop worker's code, unchanged except for the
 * {@link IosPlatform} hooks. When Dart closes the channel (shutdown, or the
 * supervisor "killing" the worker) the run loop ends and this method returns;
 * the VM stays up for the next generation.
 *
 * Options, one {@code key=value} per line:
 * <pre>
 * stateDir=DIR                    package state root (required)
 * limit.NAME=VALUE                every KTD25 limit (poolSize, operationDeadlineMs, cancelGraceMs,
 *                                 interactionTimeoutMs, shutdownGraceMs)
 * nativeDeadlineMs=N              per-operation native deadline (required)
 * browser=true|false
 * replay=DIR                      fail-closed replay from a capture directory (repeatable)
 * replayHang=HOST                 replay only: requests to HOST never get an answer (deadline tests)
 * </pre>
 */
public final class IosWorkerHost {
    private IosWorkerHost() {}

    private static volatile long stderrWorker;

    static {
        // Worker diagnostics (System.err, and System.out like the desktop main) go to the current worker's
        // stderr channel, which the supervisor redacts before logging.
        PrintStream err = new PrintStream(new ChannelOutput(-1, IosNatives.STDERR), true, StandardCharsets.UTF_8);
        System.setErr(err);
        System.setOut(err);
    }

    public static int run(long worker, String options) {
        stderrWorker = worker;
        Map<String, String> single = new LinkedHashMap<>();
        Map<String, Long> limits = new LinkedHashMap<>();
        List<File> replay = new ArrayList<>();
        List<String> hang = new ArrayList<>();
        for (String line : options.split("\n")) {
            int eq = line.indexOf('=');
            if (eq <= 0) continue;
            String key = line.substring(0, eq).trim();
            String value = line.substring(eq + 1).trim();
            if (key.startsWith("limit.")) limits.put(key.substring(6), Long.parseLong(value));
            else if (key.equals("replay")) replay.add(new File(value));
            else if (key.equals("replayHang")) hang.add(value);
            else single.put(key, value);
        }
        // No iOS sizing rule exists yet (KTD25 needs physical-iPhone benchmarks); the desktop rule must not
        // apply here, so every limit is explicit and reported as overridden.
        SizingReport sizing = SizingReport.Companion.resolve(limits, null);
        if (sizing == null) {
            System.err.println("[ios-worker] every limit must be configured: " + limits.keySet());
            return 64;
        }
        String stateDir = single.get("stateDir");
        String nativeDeadline = single.get("nativeDeadlineMs");
        if (stateDir == null || nativeDeadline == null) {
            System.err.println("[ios-worker] stateDir and nativeDeadlineMs are required");
            return 64;
        }
        File root = new File(stateDir);
        root.mkdirs();
        HostTransport transport = replay.isEmpty() ? HostTransport.Companion.getLIVE() : replayTransport(replay, Set.copyOf(hang));
        WorkerOptions workerOptions = new WorkerOptions(
                sizing,
                transport,
                replay.isEmpty() ? "live" : "replay",
                root,
                !"false".equals(single.get("browser")),
                WorkerOptions.DEFAULT_USER_AGENT,
                new IosPlatform(worker, Long.parseLong(nativeDeadline)));
        try {
            return new Worker(new ChannelInput(worker), new ChannelOutput(worker, IosNatives.STDOUT), workerOptions).run();
        } finally {
            if (transport instanceof AutoCloseable c) {
                try {
                    c.close();
                } catch (Exception e) {
                    System.err.println("[ios-worker] closing transport: " + e);
                }
            }
            deleteRecursively(root);
        }
    }

    private static HostTransport replayTransport(List<File> dirs, Set<String> hang) {
        if (hang.isEmpty()) return ReplayTransport.Companion.start(dirs);
        List<CaptureFormat.CaptureSet> captures = new ArrayList<>();
        for (File d : dirs) captures.add(CaptureFormat.INSTANCE.load(d));
        ReplayLog log = new ReplayLog();
        return new LoopbackTransport((method, url, headers, body) -> hang.contains(url.host())
                ? new MockResponse.Builder().headersDelay(1, TimeUnit.HOURS).body("").build()
                : ReplayTransport.Companion.respond(captures, log, method, url, body));
    }

    private static void deleteRecursively(File f) {
        File[] children = f.listFiles();
        if (children != null) for (File c : children) deleteRecursively(c);
        try {
            Files.deleteIfExists(f.toPath());
        } catch (IOException ignored) {
            // Best effort: the next start uses a fresh directory.
        }
    }

    private static final class ChannelInput extends InputStream {
        private final long worker;

        ChannelInput(long worker) {
            this.worker = worker;
        }

        @Override
        public int read() {
            byte[] one = new byte[1];
            int n = read(one, 0, 1);
            return n <= 0 ? -1 : one[0] & 0xff;
        }

        @Override
        public int read(byte[] b, int off, int len) {
            if (len == 0) return 0;
            return IosNatives.read(worker, b, off, len);
        }
    }

    private static final class ChannelOutput extends OutputStream {
        private final long worker;
        private final int stream;

        /** {@code worker} -1 means the current worker (process-global stderr). */
        ChannelOutput(long worker, int stream) {
            this.worker = worker;
            this.stream = stream;
        }

        private long target() {
            return worker >= 0 ? worker : stderrWorker;
        }

        @Override
        public void write(int b) {
            write(new byte[] {(byte) b}, 0, 1);
        }

        @Override
        public void write(byte[] b, int off, int len) {
            if (len > 0) IosNatives.write(target(), stream, b, off, len);
        }
    }
}
