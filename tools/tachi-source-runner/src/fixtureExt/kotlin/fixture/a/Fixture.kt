package fixture.a

import fixture.common.SimpleSite

class Factory : eu.kanade.tachiyomi.source.SourceFactory {
    override fun createSources() = listOf(SimpleSite("Fixture A", "https://fixture-a.test", fixture.shared.Dup.TAG))
}

