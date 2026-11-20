package mangabackup.tachi.host

import java.io.IOException

/**
 * Host failures that cross extension code. They extend [IOException] so
 * OkHttp's interceptor chain (and Mihon's UncaughtExceptionInterceptor) passes
 * them through unchanged; the worker maps them to protocol error codes by
 * walking the cause chain and the operation's recorded host failures.
 */
open class HostOperationException(message: String, val code: String, val operation: String?, cause: Throwable? = null) :
    IOException(message, cause)

class InteractionRequiredException(message: String, operation: String? = null, cause: Throwable? = null) :
    HostOperationException(message, "interaction-required", operation, cause)

class CapabilityUnavailableException(message: String, operation: String, cause: Throwable? = null) :
    HostOperationException(message, "capability-unavailable", operation, cause)

class HostCancelledException(message: String) : HostOperationException(message, "cancelled", null)

