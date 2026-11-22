package android.os;

public final class Message {
    public int what;
    public int arg1;
    public int arg2;
    public Object obj;
    Handler target;
    Runnable callback;

    public Message() { }

    public static Message obtain() { return new Message(); }

    public void sendToTarget() { target.sendMessage(this); }
}

