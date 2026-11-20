package android.webkit;

public class ConsoleMessage {
    public enum MessageLevel { TIP, LOG, WARNING, ERROR, DEBUG }

    private final String message;
    private final String sourceId;
    private final int lineNumber;
    private final MessageLevel level;

    public ConsoleMessage(String message, String sourceId, int lineNumber, MessageLevel level) {
        this.message = message;
        this.sourceId = sourceId;
        this.lineNumber = lineNumber;
        this.level = level;
    }

    public String message() { return message; }
    public String sourceId() { return sourceId; }
    public int lineNumber() { return lineNumber; }
    public MessageLevel messageLevel() { return level; }
}

