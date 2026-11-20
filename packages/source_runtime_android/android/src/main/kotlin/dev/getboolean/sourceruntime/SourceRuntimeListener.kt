package dev.getboolean.sourceruntime

/**
 * Callbacks from [SourceRuntimeClient] to the Dart backend.
 *
 * Dart implements this interface through JNIgen with every method registered
 * as a listener: the Java caller posts the call to the Dart isolate and
 * returns immediately. All methods return `void` so no Java thread ever waits
 * for Dart (KTD18, KTD23). Callers invoke them from the client's own executor
 * thread, never from a Binder thread.
 */
interface SourceRuntimeListener {
    /** A bind of [generation] completed; the service reported [pid]. */
    fun onBound(generation: Long, pid: Int, sdkInt: Int)

    /** A bind of [generation] failed before the service connected. */
    fun onBindFailed(generation: Long, message: String)

    /** Reply to the dispatch [callId] made on [generation]. */
    fun onReply(callId: Long, generation: Long, ok: Boolean, payload: String)

    /**
     * The service process of [generation] died (binder death notification).
     * Every call still pending on that generation will never be answered.
     */
    fun onDeath(generation: Long, pid: Int)
}
