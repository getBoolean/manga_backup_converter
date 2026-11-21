package mangabackup.tachi

import mangabackup.tachi.protocol.ArtifactRewrite
import mangabackup.tachi.protocol.DeadlineTimer
import mangabackup.tachi.protocol.OperationGuard
import mangabackup.tachi.protocol.PausableDeadline
import mangabackup.tachi.protocol.WorkerPlatform
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/** Deadline pause accounting (protocol 1.3 `interaction.started` / `interaction.ended`) over an arm/disarm timer. */
class InteractionDeadlineTest {
    private class FakeTimer : DeadlineTimer {
        val arms = mutableListOf<Long>()
        var armed = false
        var fired = false
        var firedNow = 0

        override fun arm(ms: Long) {
            check(!armed) { "armed twice without a disarm" }
            arms += ms
            armed = true
        }

        override fun disarm(): Boolean {
            val f = armed && fired
            armed = false
            fired = false
            return f
        }

        override fun fireNow() {
            firedNow++
            fired = true
        }
    }

    private var nowNanos = 0L
    private fun advance(ms: Long) {
        nowNanos += ms * 1_000_000
    }

    private fun deadline(timer: FakeTimer, budgetMs: Long = 1_000) = PausableDeadline(budgetMs, timer) { nowNanos }

    @Test
    fun `paused time is not counted and the pause is bounded by the interaction timeout`() {
        val timer = FakeTimer()
        val d = deadline(timer)
        assertEquals(listOf(1_000L), timer.arms)
        advance(300)
        d.pause(5_000)
        // Re-armed for what remained plus the bound, so a lost interaction.ended cannot leave no deadline.
        assertEquals(listOf(1_000L, 5_700L), timer.arms)
        advance(4_000)
        assertEquals(700, d.remainingMs, "paused time counted against the budget")
        d.resume()
        assertEquals(listOf(1_000L, 5_700L, 700L), timer.arms)
        advance(200)
        assertEquals(500, d.remainingMs)
        d.close()
        assertFalse(d.expired)
        assertFalse(timer.armed)
    }

    @Test
    fun `a deadline that fired before the pause stays fired`() {
        val timer = FakeTimer()
        val d = deadline(timer)
        timer.fired = true
        d.pause(5_000)
        assertTrue(d.expired)
        d.resume()
        assertEquals(listOf(1_000L), timer.arms, "a fired deadline was re-armed")
    }

    @Test
    fun `a pause that overruns its bound expires the operation at resume`() {
        val timer = FakeTimer()
        val d = deadline(timer)
        d.pause(100)
        timer.fired = true
        d.resume()
        assertTrue(d.expired)
        assertEquals(2, timer.arms.size)
    }

    @Test
    fun `nothing re-arms after close, and a repeated start is ignored`() {
        val timer = FakeTimer()
        val d = deadline(timer)
        d.pause(5_000)
        d.pause(5_000)
        assertEquals(2, timer.arms.size, "a second pause re-armed")
        d.close()
        d.resume()
        d.pause(5_000)
        assertEquals(2, timer.arms.size, "re-armed after close: the thread may be running another operation")
        assertFalse(timer.armed)
    }

    @Test
    fun `cancel during an interaction still fires the deadline`() {
        val timer = FakeTimer()
        val d = deadline(timer)
        d.pause(5_000)
        d.expireNow()
        assertEquals(1, timer.firedNow)
        d.close()
        assertTrue(d.expired)
    }
}

/**
 * A test platform with real operation deadlines (the desktop worker has none of its own) over a
 * scheduler, recording every pause and resume and every span its timers were armed for.
 */
class TestDeadlinePlatform(private val budgetMs: Long) : WorkerPlatform {
    override val name = "test-deadline"
    override val artifactRewrite: ArtifactRewrite? = null
    override fun pid(): Long? = null

    private val scheduler = Executors.newSingleThreadScheduledExecutor { r -> Thread(r, "test-deadline").apply { isDaemon = true } }
    val guards = CopyOnWriteArrayList<Recording>()

    override fun enterOperation(thread: Thread, onExpire: Runnable): OperationGuard {
        val timer = ScheduledTimer(onExpire)
        return Recording(PausableDeadline(budgetMs, timer), timer).also { guards += it }
    }

    class Recording(private val inner: PausableDeadline, val timer: ScheduledTimer) : OperationGuard by inner {
        val pauses = AtomicInteger()
        val resumes = AtomicInteger()

        override fun pause(boundMs: Long) {
            pauses.incrementAndGet()
            inner.pause(boundMs)
        }

        override fun resume() {
            resumes.incrementAndGet()
            inner.resume()
        }
    }

    /** One armed span at a time; a span that started firing counts as fired even if its action is still running. */
    inner class ScheduledTimer(private val onExpire: Runnable) : DeadlineTimer {
        val arms = CopyOnWriteArrayList<Long>()
        private val lock = Any()
        private var span: Span? = null

        private inner class Span {
            var disarmed = false
            var fired = false
            var future: ScheduledFuture<*>? = null

            fun run() {
                synchronized(lock) {
                    if (disarmed || fired) return
                    fired = true
                }
                onExpire.run()
            }
        }

        override fun arm(ms: Long) {
            arms += ms
            val s = Span()
            synchronized(lock) {
                span = s
                s.future = scheduler.schedule(s::run, ms, TimeUnit.MILLISECONDS)
            }
        }

        override fun disarm(): Boolean = synchronized(lock) {
            val s = span ?: return false
            span = null
            s.disarmed = true
            s.future?.cancel(false)
            s.fired
        }

        override fun fireNow() {
            val s = synchronized(lock) { span } ?: return
            scheduler.execute(s::run)
        }
    }
}
