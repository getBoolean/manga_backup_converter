package mangabackup.tachi.extensions

import java.io.File
import java.security.MessageDigest

object Digests {
    fun sha256(file: File): String {
        val md = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val n = input.read(buffer)
                if (n < 0) break
                md.update(buffer, 0, n)
            }
        }
        return md.digest().toHex()
    }

    fun sha256(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes).toHex()

    fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }

    /** Fails unless [file] hashes to [expected] (lowercase hex). */
    fun requireSha256(file: File, expected: String, what: String) {
        val actual = sha256(file)
        if (!actual.equals(expected, ignoreCase = true)) {
            throw ArtifactException("$what digest mismatch: expected $expected, found $actual")
        }
    }
}

