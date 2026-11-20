package dev.getboolean.sourceruntime

import android.content.Context
import android.system.Os
import android.system.OsConstants
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.security.MessageDigest

/**
 * Private, read-only staging for extension artifacts (KTD17, Android 14
 * dynamic-code-loading rules).
 *
 * Every staged file is created in no-backup app storage and marked read-only
 * through its path *before* any byte is written; the content goes through the
 * descriptor that was already open. A staged artifact is therefore never
 * writable by path, on any API level.
 */
object ArtifactStaging {
    private val SAFE_NAME = Regex("^[A-Za-z0-9._-]{1,128}$")
    private val SHA256_HEX = Regex("^[0-9a-f]{64}$")

    /** Directory that holds staged artifacts. */
    fun stagingDirectory(context: Context): String = stagingDir(context).absolutePath

    /**
     * Stages the asset [assetName] as `<expectedSha256>.apk` and returns its
     * path. Fails, leaving nothing staged, if the digest does not match.
     */
    fun stageAsset(context: Context, assetName: String, expectedSha256: String): String {
        require(SHA256_HEX.matches(expectedSha256)) { "expected digest must be lowercase SHA-256 hex" }
        val target = File(stagingDir(context), "$expectedSha256.apk")
        val actual = context.assets.open(assetName).use { input -> writeReadOnly(target, input) }
        if (actual != expectedSha256) {
            target.delete()
            throw SecurityException("staged digest $actual does not match expected $expectedSha256")
        }
        return target.absolutePath
    }

    /** Stages [bytes] read-only as [name] without a digest check. */
    fun stageBytes(context: Context, name: String, bytes: ByteArray): String {
        require(SAFE_NAME.matches(name)) { "unsafe staging name: $name" }
        val target = File(stagingDir(context), name)
        writeReadOnly(target, bytes.inputStream())
        return target.absolutePath
    }

    /** Removes a staged file. */
    fun delete(path: String): Boolean = File(path).delete()

    /** Lowercase SHA-256 hex of [file]. */
    internal fun sha256(file: File): String = file.inputStream().use { input ->
        val digest = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(64 * 1024)
        while (true) {
            val n = input.read(buffer)
            if (n < 0) break
            digest.update(buffer, 0, n)
        }
        digest.digest().toHex()
    }

    /**
     * True if [file] has any write permission bit set or is writable by this
     * process. Checked before every load (not only on API 34+, where the
     * platform also refuses writable DEX).
     */
    internal fun isWritable(file: File): Boolean {
        val mode = Os.stat(file.absolutePath).st_mode
        val writeBits = OsConstants.S_IWUSR or OsConstants.S_IWGRP or OsConstants.S_IWOTH
        return (mode and writeBits) != 0 || file.canWrite()
    }

    private fun stagingDir(context: Context): File =
        File(context.noBackupFilesDir, "source_runtime/artifacts").apply { mkdirs() }

    private fun writeReadOnly(target: File, input: InputStream): String {
        val partial = File(target.parentFile, "${target.name}.partial")
        partial.delete()
        target.delete()
        val digest = MessageDigest.getInstance("SHA-256")
        FileOutputStream(partial).use { out ->
            // Read-only before writing: the open descriptor stays writable.
            check(partial.setReadOnly()) { "could not mark ${partial.name} read-only" }
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val n = input.read(buffer)
                if (n < 0) break
                digest.update(buffer, 0, n)
                out.write(buffer, 0, n)
            }
            out.fd.sync()
        }
        check(partial.renameTo(target)) { "could not move staged ${target.name} into place" }
        return digest.digest().toHex()
    }

    private fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }
}
