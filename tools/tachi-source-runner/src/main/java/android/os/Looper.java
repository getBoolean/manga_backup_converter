package android.os;

import java.util.Iterator;
import java.util.PriorityQueue;

/**
 * Worker-owned message loops. {@link #getMainLooper()} is a single daemon
 * thread ("tachi-main") that plays Android's main thread, so extension code
 * that posts to the main looper and blocks a background thread on a latch
 * (as {@code keiyoushi.utils.runWebViewBlocking} does) completes instead of
 * deadlocking. A task that throws is logged and the loop continues; on
 * Android it would crash the app, here it fails only that task.
 */
public final class Looper {
    private static final ThreadLocal<Looper> CURRENT = new ThreadLocal<>();
    private static volatile Looper main;

    final Object lock = new Object();
    final PriorityQueue<Entry> queue = new PriorityQueue<>();
    private long seq;
    private boolean quitting;
    private Thread thread;

    record Entry(long when, long seq, Handler handler, Message message) implements Comparable<Entry> {
        @Override
        public int compareTo(Entry o) {
            int c = Long.compare(when, o.when);
            return c != 0 ? c : Long.compare(seq, o.seq);
        }
    }

    private Looper() { }

    public static void prepare() {
        if (CURRENT.get() != null) throw new RuntimeException("Only one Looper may be created per thread");
        Looper l = new Looper();
        l.thread = Thread.currentThread();
        CURRENT.set(l);
    }

    public static Looper myLooper() { return CURRENT.get(); }

    public static Looper getMainLooper() {
        Looper l = main;
        if (l != null) return l;
        synchronized (Looper.class) {
            if (main == null) {
                Looper created = new Looper();
                Thread t = new Thread(() -> {
                    CURRENT.set(created);
                    loop();
                }, "tachi-main");
                t.setDaemon(true);
                created.thread = t;
                main = created;
                t.start();
            }
            return main;
        }
    }

    public Thread getThread() { return thread; }

    public boolean isCurrentThread() { return Thread.currentThread() == thread; }

    public static void loop() {
        Looper me = myLooper();
        if (me == null) throw new RuntimeException("No Looper; Looper.prepare() wasn't called on this thread.");
        while (true) {
            Entry next;
            synchronized (me.lock) {
                while (true) {
                    if (me.quitting) return;
                    Entry head = me.queue.peek();
                    long now = SystemClock.uptimeMillis();
                    if (head != null && head.when <= now) {
                        next = me.queue.poll();
                        break;
                    }
                    try {
                        if (head == null) me.lock.wait();
                        else me.lock.wait(Math.max(1, head.when - now));
                    } catch (InterruptedException e) {
                        // The main looper ignores interrupts; it is stopped only by quit().
                    }
                }
            }
            try {
                next.handler.dispatchMessage(next.message);
            } catch (Throwable t) {
                System.err.println("[host] uncaught exception on looper " + me.thread.getName() + ": " + t);
                t.printStackTrace(System.err);
            }
        }
    }

    public void quit() {
        synchronized (lock) {
            quitting = true;
            queue.clear();
            lock.notifyAll();
        }
    }

    void enqueue(Handler handler, Message message, long when) {
        synchronized (lock) {
            queue.add(new Entry(when, seq++, handler, message));
            lock.notifyAll();
        }
    }

    void remove(Handler handler, Runnable callback, Object token, boolean all) {
        synchronized (lock) {
            Iterator<Entry> it = queue.iterator();
            while (it.hasNext()) {
                Entry e = it.next();
                if (e.handler != handler) continue;
                if (all || (callback != null && e.message.callback == callback)) it.remove();
            }
        }
    }

    void removeWhat(Handler handler, int what) {
        synchronized (lock) {
            queue.removeIf(e -> e.handler == handler && e.message.callback == null && e.message.what == what);
        }
    }

    /** Number of queued messages; used by tests. */
    public int pendingCount() {
        synchronized (lock) {
            return queue.size();
        }
    }
}

