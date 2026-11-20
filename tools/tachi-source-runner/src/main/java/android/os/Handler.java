package android.os;

public class Handler {
    public interface Callback {
        boolean handleMessage(Message msg);
    }

    private final Looper looper;
    private final Callback callback;

    public Handler() { this(requireMyLooper(), null); }

    public Handler(Looper looper) { this(looper, null); }

    public Handler(Looper looper, Callback callback) {
        if (looper == null) throw new NullPointerException("looper");
        this.looper = looper;
        this.callback = callback;
    }

    private static Looper requireMyLooper() {
        Looper l = Looper.myLooper();
        if (l == null) throw new RuntimeException("Can't create handler inside thread that has not called Looper.prepare()");
        return l;
    }

    public final Looper getLooper() { return looper; }

    public void handleMessage(Message msg) { }

    public void dispatchMessage(Message msg) {
        if (msg.callback != null) {
            msg.callback.run();
        } else if (callback == null || !callback.handleMessage(msg)) {
            handleMessage(msg);
        }
    }

    public final boolean post(Runnable r) { return postDelayed(r, 0); }

    public final boolean postDelayed(Runnable r, long delayMillis) {
        Message m = new Message();
        m.callback = r;
        return sendMessageDelayed(m, delayMillis);
    }

    public final boolean postAtTime(Runnable r, long uptimeMillis) {
        Message m = new Message();
        m.callback = r;
        m.target = this;
        looper.enqueue(this, m, uptimeMillis);
        return true;
    }

    public final boolean postAtFrontOfQueue(Runnable r) {
        Message m = new Message();
        m.callback = r;
        m.target = this;
        looper.enqueue(this, m, Long.MIN_VALUE);
        return true;
    }

    public final void removeCallbacks(Runnable r) { looper.remove(this, r, null, false); }

    public final void removeCallbacksAndMessages(Object token) { looper.remove(this, null, token, true); }

    public final void removeMessages(int what) { looper.removeWhat(this, what); }

    public final Message obtainMessage() { Message m = new Message(); m.target = this; return m; }

    public final Message obtainMessage(int what) { Message m = obtainMessage(); m.what = what; return m; }

    public final Message obtainMessage(int what, Object obj) { Message m = obtainMessage(what); m.obj = obj; return m; }

    public final boolean sendMessage(Message msg) { return sendMessageDelayed(msg, 0); }

    public final boolean sendEmptyMessage(int what) { return sendMessage(obtainMessage(what)); }

    public final boolean sendEmptyMessageDelayed(int what, long delayMillis) { return sendMessageDelayed(obtainMessage(what), delayMillis); }

    public final boolean sendMessageDelayed(Message msg, long delayMillis) {
        msg.target = this;
        looper.enqueue(this, msg, SystemClock.uptimeMillis() + Math.max(0, delayMillis));
        return true;
    }
}

