package mangabackup.tachi.extensions

import com.android.apksig.ApkVerifier
import mangabackup.tachi.extensions.Digests.toHex
import java.io.File
import java.security.MessageDigest
import java.security.cert.X509Certificate
import java.util.jar.JarFile
import java.util.zip.ZipFile

/**
 * KTD5 signature checks, run before any conversion or class loading.
 *
 * JAR path: every entry except the signature files themselves must be listed in
 * the signed manifest and verify against exactly one signer whose certificate
 * SHA-256 is trusted. Standard JAR verification silently accepts unsigned
 * entries, so an unsigned, extra or mixed-signer entry is rejected here.
 *
 * APK path: pinned apksig verifies the APK signature schemes against the same
 * trust identity.
 */
object ArtifactVerifier {
    data class Verified(val signerSha256: String, val schemes: List<String>)

    fun certificateSha256(cert: X509Certificate): String = MessageDigest.getInstance("SHA-256").digest(cert.encoded).toHex()

    /** Signature-block files that are not themselves covered by the manifest. */
    fun isSignatureFile(name: String): Boolean {
        val upper = name.uppercase()
        if (!upper.startsWith("META-INF/")) return false
        val rest = upper.removePrefix("META-INF/")
        if (rest.contains('/')) return false
        return rest == "MANIFEST.MF" || rest.endsWith(".SF") || rest.endsWith(".RSA") || rest.endsWith(".DSA") ||
            rest.endsWith(".EC") || rest.startsWith("SIG-")
    }

    fun verifyJar(file: File, trustedSigners: Set<String>): Verified {
        if (trustedSigners.isEmpty()) throw ArtifactException("No trusted signing identity was supplied for ${file.name}")
        requireUniqueEntries(file)
        val signers = HashSet<String>()
        var signedEntries = 0
        JarFile(file, true).use { jar ->
            if (jar.manifest == null) throw ArtifactException("${file.name} has no META-INF/MANIFEST.MF; it is not a signed JAR")
            val buffer = ByteArray(16 * 1024)
            for (entry in jar.entries()) {
                // Reading each entry fully is what makes JarFile check its digest.
                jar.getInputStream(entry).use { input ->
                    try {
                        while (input.read(buffer) >= 0) Unit
                    } catch (e: SecurityException) {
                        throw ArtifactException("${file.name}: entry ${entry.name} failed digest verification", e)
                    }
                }
                if (entry.isDirectory || isSignatureFile(entry.name)) continue
                val codeSigners = entry.codeSigners
                    ?: throw ArtifactException("${file.name}: entry ${entry.name} is not covered by the signature")
                if (codeSigners.size != 1) {
                    throw ArtifactException("${file.name}: entry ${entry.name} has ${codeSigners.size} signers; exactly one is required")
                }
                val cert = codeSigners[0].signerCertPath.certificates.firstOrNull() as? X509Certificate
                    ?: throw ArtifactException("${file.name}: entry ${entry.name} has no X.509 signer certificate")
                signers += certificateSha256(cert)
                signedEntries++
            }
        }
        if (signedEntries == 0) throw ArtifactException("${file.name} has no signed entries")
        if (signers.size != 1) throw ArtifactException("${file.name} is signed by ${signers.size} different signers")
        val signer = signers.single()
        if (signer !in trustedSigners.map { it.lowercase() }) {
            throw ArtifactException("${file.name} is signed by untrusted certificate $signer")
        }
        return Verified(signer, listOf("jar"))
    }

    fun verifyApk(file: File, trustedSigners: Set<String>): Verified {
        if (trustedSigners.isEmpty()) throw ArtifactException("No trusted signing identity was supplied for ${file.name}")
        // apksig verifies the entries it reads; a later reader (dex2jar, ART)
        // could pick the other copy of a duplicated name (L5).
        requireUniqueEntries(file)
        val result = try {
            ApkVerifier.Builder(file).build().verify()
        } catch (e: Exception) {
            throw ArtifactException("${file.name}: APK signature verification failed: ${e.message}", e)
        }
        if (!result.isVerified) {
            val errors = result.allErrors.joinToString("; ") { it.toString() }
            throw ArtifactException("${file.name}: APK signature is not valid: $errors")
        }
        val certs = result.signerCertificates
        if (certs.size != 1) throw ArtifactException("${file.name}: APK has ${certs.size} signers; exactly one is required")
        val signer = certificateSha256(certs.single())
        if (signer !in trustedSigners.map { it.lowercase() }) {
            throw ArtifactException("${file.name} is signed by untrusted certificate $signer")
        }
        val schemes = buildList {
            if (result.isVerifiedUsingV1Scheme) add("v1")
            if (result.isVerifiedUsingV2Scheme) add("v2")
            if (result.isVerifiedUsingV3Scheme) add("v3")
            if (result.isVerifiedUsingV31Scheme) add("v3.1")
            if (result.isVerifiedUsingV4Scheme) add("v4")
        }
        return Verified(signer, schemes)
    }

    /** A ZIP with duplicate entry names can verify one copy and load another. */
    internal fun requireUniqueEntries(file: File) {
        try {
            ZipFile(file).use { zip ->
                val seen = HashSet<String>()
                for (entry in zip.entries()) {
                    if (!seen.add(entry.name)) throw ArtifactException("${file.name} contains duplicate entry ${entry.name}")
                }
            }
        } catch (e: java.util.zip.ZipException) {
            throw ArtifactException("${file.name} is not a valid ZIP archive: ${e.message}", e)
        }
    }
}

