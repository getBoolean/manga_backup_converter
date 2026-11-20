package mihon.core.common.extensions

import kotlinx.serialization.json.JsonObject

/** Replaces Mihon's `JsonObject.EMPTY` used by the extracted model classes. */
val JsonObject.Companion.EMPTY: JsonObject get() = EMPTY_OBJECT

private val EMPTY_OBJECT = JsonObject(emptyMap())

