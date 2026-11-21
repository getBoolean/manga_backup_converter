package mangabackup.tachi.protocol

import mangabackup.tachi.host.HostTransport
import mangabackup.tachi.host.SizingReport
import java.io.File

data class WorkerOptions(
    val sizing: SizingReport,
    val transport: HostTransport = HostTransport.LIVE,
    val networkMode: String = "live",
    val stateRoot: File,
    val browser: Boolean = true,
    val defaultUserAgent: String = DEFAULT_USER_AGENT,
    /** The hosting process: [DesktopPlatform] for the desktop worker; Android and iOS pass their own. */
    val platform: WorkerPlatform,
) {
    companion object {
        const val WORKER_NAME = "tachi-jvm"
        const val WORKER_VERSION = "0.1.0"

        /** Host compatibility version: part of every prepared artifact's cache identity. */
        const val HOST_COMPATIBILITY = "tachi-host.1"

        const val DEFAULT_USER_AGENT =
            "Mozilla/5.0 (Linux; Android 15; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Mobile Safari/537.36"
    }
}
