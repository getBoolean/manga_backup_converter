package mangabackup.tachi.host

import android.content.SharedPreferences
import java.util.concurrent.CopyOnWriteArraySet

/**
 * Host-supplied SharedPreferences (KTD9). Lives only in memory: seeded from the
 * conversion's settings snapshot, mutated by the extension, discarded when the
 * package unloads or the session closes. Nothing is ever written to disk, so a
 * password seeded here cannot reach a preference file.
 *
 * Typing follows Android: reading a key with the wrong getter throws
 * ClassCastException. Integers from JSON are stored as Long and served to
 * getInt/getLong/getFloat.
 */
class InMemorySharedPreferences(seed: Map<String, Any>) : SharedPreferences {
    private val lock = Any()
    private val values = HashMap<String, Any>()
    private val listeners = CopyOnWriteArraySet<SharedPreferences.OnSharedPreferenceChangeListener>()

    init {
        reset(seed)
    }

    fun reset(seed: Map<String, Any>) {
        synchronized(lock) {
            values.clear()
            for ((k, v) in seed) values[k] = normalize(v)
        }
    }

    private fun normalize(v: Any): Any = when (v) {
        is Int -> v.toLong()
        is Short -> v.toLong()
        is Byte -> v.toLong()
        is Set<*> -> v.map { it.toString() }.toSet()
        else -> v
    }

    override fun getAll(): Map<String, *> = synchronized(lock) { HashMap(values) }

    override fun getString(key: String, defValue: String?): String? = synchronized(lock) {
        when (val v = values[key]) {
            null -> defValue
            is String -> v
            else -> throw ClassCastException("$key is ${v.javaClass.simpleName}, not String")
        }
    }

    override fun getStringSet(key: String, defValues: Set<String>?): Set<String>? = synchronized(lock) {
        when (val v = values[key]) {
            null -> defValues
            is Set<*> -> v.map { it.toString() }.toSet()
            else -> throw ClassCastException("$key is ${v.javaClass.simpleName}, not Set<String>")
        }
    }

    override fun getInt(key: String, defValue: Int): Int = synchronized(lock) {
        when (val v = values[key]) {
            null -> defValue
            is Number -> v.toInt()
            else -> throw ClassCastException("$key is ${v.javaClass.simpleName}, not Integer")
        }
    }

    override fun getLong(key: String, defValue: Long): Long = synchronized(lock) {
        when (val v = values[key]) {
            null -> defValue
            is Number -> v.toLong()
            else -> throw ClassCastException("$key is ${v.javaClass.simpleName}, not Long")
        }
    }

    override fun getFloat(key: String, defValue: Float): Float = synchronized(lock) {
        when (val v = values[key]) {
            null -> defValue
            is Number -> v.toFloat()
            else -> throw ClassCastException("$key is ${v.javaClass.simpleName}, not Float")
        }
    }

    override fun getBoolean(key: String, defValue: Boolean): Boolean = synchronized(lock) {
        when (val v = values[key]) {
            null -> defValue
            is Boolean -> v
            else -> throw ClassCastException("$key is ${v.javaClass.simpleName}, not Boolean")
        }
    }

    override fun contains(key: String): Boolean = synchronized(lock) { values.containsKey(key) }

    override fun edit(): SharedPreferences.Editor = Editor()

    override fun registerOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener) {
        listeners.add(listener)
    }

    override fun unregisterOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener) {
        listeners.remove(listener)
    }

    private inner class Editor : SharedPreferences.Editor {
        private val pending = LinkedHashMap<String, Any?>()
        private var clear = false

        override fun putString(key: String, value: String?) = apply { pending[key] = value }
        override fun putStringSet(key: String, values: Set<String>?) = apply { pending[key] = values?.toSet() }
        override fun putInt(key: String, value: Int) = apply { pending[key] = value.toLong() }
        override fun putLong(key: String, value: Long) = apply { pending[key] = value }
        override fun putFloat(key: String, value: Float) = apply { pending[key] = value }
        override fun putBoolean(key: String, value: Boolean) = apply { pending[key] = value }
        override fun remove(key: String) = apply { pending[key] = null }
        override fun clear() = apply { clear = true }

        override fun commit(): Boolean {
            val changed = ArrayList<String>()
            synchronized(lock) {
                if (clear) {
                    changed += values.keys
                    values.clear()
                }
                for ((k, v) in pending) {
                    if (v == null) values.remove(k) else values[k] = v
                    changed += k
                }
            }
            for (key in changed.distinct()) {
                for (l in listeners) l.onSharedPreferenceChanged(this@InMemorySharedPreferences, key)
            }
            return true
        }

        override fun apply() {
            commit()
        }
    }
}

