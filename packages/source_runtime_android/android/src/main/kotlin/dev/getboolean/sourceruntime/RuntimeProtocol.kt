package dev.getboolean.sourceruntime

import android.os.IBinder

/**
 * Binder transaction codes shared by [SourceRuntimeClient] (app process) and
 * [SourceRuntimeService] (`:source_runtime` process).
 *
 * Binder carries only bounded control messages. Every dispatch is one-way and
 * carries a reply binder, so no app-process thread blocks on the service and
 * no Binder thread ever waits on Dart (KTD18).
 */
internal object RuntimeProtocol {
    const val DESCRIPTOR = "dev.getboolean.sourceruntime.IRuntime"

    /** Synchronous, bounded: replies with the service PID and SDK level. */
    const val HELLO = IBinder.FIRST_CALL_TRANSACTION

    /** One-way: callId, op, argsJson, reply binder. */
    const val DISPATCH = IBinder.FIRST_CALL_TRANSACTION + 1

    /** One-way, service to client on the reply binder: callId, ok, payload. */
    const val REPLY = IBinder.FIRST_CALL_TRANSACTION + 2

    const val REPLY_DESCRIPTOR = "dev.getboolean.sourceruntime.IReply"

    /** Upper bound for any string carried in one Binder transaction. */
    const val MAX_MESSAGE_CHARS = 256 * 1024
}
