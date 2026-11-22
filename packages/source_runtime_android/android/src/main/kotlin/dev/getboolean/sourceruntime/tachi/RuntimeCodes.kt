package dev.getboolean.sourceruntime.tachi

import android.os.IBinder

/**
 * Binder transaction codes of the Tachi worker channel, beside the U17 gate
 * codes in `RuntimeProtocol` (same service binder, same descriptors).
 *
 * App → service: [WORKER_OPEN] and [WORKER_FRAME_IN] are one-way; starting a
 * worker can take seconds (replay set-up, WebView initialization on the
 * service's main looper), so its outcome comes back as [WORKER_STARTED]. Service → app, all one-way on the app's
 * reply binder: [WORKER_FRAME], [WORKER_LOG], [WORKER_EXIT]. No transaction
 * ever waits on Dart (KTD18).
 */
internal object RuntimeCodes {
    const val DESCRIPTOR = "dev.getboolean.sourceruntime.IRuntime"
    const val REPLY_DESCRIPTOR = "dev.getboolean.sourceruntime.IReply"

    /** One-way: argsJson, reply binder. The outcome arrives as [WORKER_STARTED]. */
    const val WORKER_OPEN = IBinder.FIRST_CALL_TRANSACTION + 3

    /** One-way: one frame ([FrameTransport]). */
    const val WORKER_FRAME_IN = IBinder.FIRST_CALL_TRANSACTION + 4

    /** One-way on the reply binder: one frame ([FrameTransport]). */
    const val WORKER_FRAME = IBinder.FIRST_CALL_TRANSACTION + 10

    /** One-way on the reply binder: one stderr line. */
    const val WORKER_LOG = IBinder.FIRST_CALL_TRANSACTION + 11

    /** One-way on the reply binder: the worker's exit code; the process ends right after. */
    const val WORKER_EXIT = IBinder.FIRST_CALL_TRANSACTION + 12

    /** One-way on the reply binder: the start outcome, an error message or null. */
    const val WORKER_STARTED = IBinder.FIRST_CALL_TRANSACTION + 13
}
