package mangabackup.tachi

import mangabackup.tachi.extensions.ArtifactVerifier
import org.bouncycastle.asn1.x500.X500Name
import org.bouncycastle.cert.jcajce.JcaX509CertificateConverter
import org.bouncycastle.cert.jcajce.JcaX509v3CertificateBuilder
import org.bouncycastle.operator.jcajce.JcaContentSignerBuilder
import java.io.File
import java.math.BigInteger
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.util.Date
import java.util.zip.ZipFile
import jdk.security.jarsigner.JarSigner

/** A throwaway signing key for re-signing tests. */
object TestSigning {
    private val keyPair = KeyPairGenerator.getInstance("RSA").apply { initialize(2048) }.generateKeyPair()
    private val certificate: X509Certificate = run {
        val name = X500Name("CN=tachi-source-runner test signer")
        val now = System.currentTimeMillis()
        val builder = JcaX509v3CertificateBuilder(name, BigInteger.valueOf(now), Date(now - 86_400_000), Date(now + 86_400_000L * 365), name, keyPair.public)
        val signer = JcaContentSignerBuilder("SHA256withRSA").build(keyPair.private)
        JcaX509CertificateConverter().getCertificate(builder.build(signer))
    }
    val certificateSha256: String = ArtifactVerifier.certificateSha256(certificate)

    /** Strips the original signature and signs [input] with the test key. */
    fun resign(input: File, output: File) {
        val unsigned = File(output.parentFile, "unsigned-" + output.name)
        ZipFile(input).use { zip ->
            java.util.zip.ZipOutputStream(unsigned.outputStream()).use { zos ->
                for (e in zip.entries()) {
                    if (ArtifactVerifier.isSignatureFile(e.name)) continue
                    zos.putNextEntry(java.util.zip.ZipEntry(e.name))
                    zip.getInputStream(e).use { it.copyTo(zos) }
                    zos.closeEntry()
                }
            }
        }
        val certPath = CertificateFactory.getInstance("X.509").generateCertPath(listOf(certificate))
        val signer = JarSigner.Builder(keyPair.private, certPath).digestAlgorithm("SHA-256").signatureAlgorithm("SHA256withRSA").build()
        ZipFile(unsigned).use { zip -> output.outputStream().use { out -> signer.sign(zip, out) } }
        unsigned.delete()
    }

    @Suppress("unused")
    private val unusedKeyStore: KeyStore? = null
}
