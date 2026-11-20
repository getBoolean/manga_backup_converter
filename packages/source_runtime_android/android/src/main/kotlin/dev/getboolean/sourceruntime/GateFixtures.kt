package dev.getboolean.sourceruntime

import org.json.JSONObject

/**
 * Fixture operations for the U17 runtime gate: behaviour that a hostile or
 * buggy extension could exhibit, used to prove the termination boundary.
 */
internal object GateFixtures {
    @Volatile
    private var spins = 0L

    /**
     * A call-free CPU loop that never returns and ignores interruption. Only
     * killing the `:source_runtime` process ends it (KTD18).
     */
    fun cpuLoop(): JSONObject {
        while (true) {
            spins++
        }
    }
}
