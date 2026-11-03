package org.teavm.classlib.java.util.concurrent.locks;

/**
 * Single-threaded TeaVM substitute for {@code ReentrantLock}.
 *
 * <p>The web parser runs inside one worker, so jsoup's parser lock only needs
 * the lock/unlock API surface when compiled to JavaScript.</p>
 */
public final class TReentrantLock {
    public TReentrantLock() {}

    public void lock() {}

    public void unlock() {}
}
