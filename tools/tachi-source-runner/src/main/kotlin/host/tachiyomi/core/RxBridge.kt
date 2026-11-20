package tachiyomi.core.common.util.lang

import kotlinx.coroutines.suspendCancellableCoroutine
import rx.Observable
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * Awaits the single item of a legacy (extensions-lib 1.4/1.5) RxJava
 * observable. Replaces Mihon's `tachiyomi.core.common.util.lang.awaitSingle`.
 */
suspend fun <T> Observable<T>.awaitSingle(): T = suspendCancellableCoroutine { continuation ->
    val subscription = single().subscribe(
        { value -> if (continuation.isActive) continuation.resume(value) },
        { error -> if (continuation.isActive) continuation.resumeWithException(error) },
    )
    continuation.invokeOnCancellation { subscription.unsubscribe() }
}

