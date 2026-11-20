// Extracted from Mihon (https://github.com/mihonapp/mihon) at f64d82b94218b42410c36e6c85da818574865a28,
// Apache License 2.0. Copyright the Mihon Open Source Project and Tachiyomi contributors.
// Changes for the desktop Tachi host are marked "desktop host:"; see THIRD_PARTY.md.

@file:Suppress("PropertyName")

package eu.kanade.tachiyomi.source.model

import kotlinx.serialization.json.JsonObject
import mihon.core.common.extensions.EMPTY

class SChapterImpl : SChapter {

    override lateinit var url: String

    override lateinit var name: String

    override var chapter_number: Float = -1f

    override var scanlator: String? = null

    override var date_upload: Long = 0

    override var memo: JsonObject = JsonObject.EMPTY
}
