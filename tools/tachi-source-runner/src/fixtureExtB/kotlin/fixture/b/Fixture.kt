package fixture.b

import fixture.common.SimpleSite

class Factory : eu.kanade.tachiyomi.source.SourceFactory {
    override fun createSources() = listOf(SimpleSite("Fixture B", "https://fixture-b.test", fixture.shared.Dup.TAG))
}

