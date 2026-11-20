package mangabackup.tachi.extensions

import com.android.apksig.internal.apk.AndroidBinXmlParser
import org.w3c.dom.Element
import java.io.File
import java.nio.ByteBuffer
import java.util.zip.ZipFile
import javax.xml.XMLConstants
import javax.xml.parsers.DocumentBuilderFactory

/**
 * The parts of an extension's AndroidManifest.xml the host needs. Repository
 * JARs carry a text manifest; APKs (and JARs converted from them) carry
 * Android's binary XML. Both are read here.
 */
data class ExtensionManifest(
    val packageName: String,
    val versionName: String,
    val versionCode: Long,
    val metaData: Map<String, String>,
    val features: Set<String>,
) {
    val isTachiExtension: Boolean get() = "tachiyomi.extension" in features

    val factoryClasses: List<String>
        get() = metaData[META_CLASS].orEmpty().split(';').map { it.trim() }.filter { it.isNotEmpty() }
            .map { if (it.startsWith('.')) packageName + it else it }

    /** Extension API version: explicit `tachiyomix.extensionLib`, else the versionName's `major.minor`. */
    val libVersion: String
        get() = metaData[META_LIB] ?: versionName.split('.').take(2).joinToString(".")

    val nsfw: Boolean get() = metaData[META_NSFW] == "1"

    companion object {
        const val META_CLASS = "tachiyomi.extension.class"
        const val META_LIB = "tachiyomix.extensionLib"
        const val META_NSFW = "tachiyomi.extension.nsfw"
        private const val ANDROID_NS = "http://schemas.android.com/apk/res/android"

        fun read(archive: File): ExtensionManifest {
            val bytes = ZipFile(archive).use { zip ->
                val entry = zip.getEntry("AndroidManifest.xml")
                    ?: throw ArtifactException("${archive.name} has no AndroidManifest.xml")
                zip.getInputStream(entry).use { it.readBytes() }
            }
            return parse(bytes, archive.name)
        }

        fun parse(bytes: ByteArray, label: String): ExtensionManifest =
            if (bytes.size >= 2 && bytes[0] == 0x03.toByte() && bytes[1] == 0x00.toByte()) parseBinary(bytes, label) else parseText(bytes, label)

        private fun parseText(bytes: ByteArray, label: String): ExtensionManifest {
            val factory = DocumentBuilderFactory.newInstance().apply {
                isNamespaceAware = true
                setFeature(XMLConstants.FEATURE_SECURE_PROCESSING, true)
                setFeature("http://apache.org/xml/features/disallow-doctype-decl", true)
                isExpandEntityReferences = false
            }
            val doc = try {
                factory.newDocumentBuilder().parse(bytes.inputStream())
            } catch (e: Exception) {
                throw ArtifactException("$label: unreadable AndroidManifest.xml: ${e.message}", e)
            }
            val root = doc.documentElement
            if (root.tagName != "manifest") throw ArtifactException("$label: AndroidManifest.xml root is not <manifest>")
            fun Element.android(name: String): String? = getAttributeNS(ANDROID_NS, name).takeIf { hasAttributeNS(ANDROID_NS, name) }
            val meta = LinkedHashMap<String, String>()
            val features = LinkedHashSet<String>()
            val metaNodes = root.getElementsByTagName("meta-data")
            for (i in 0 until metaNodes.length) {
                val e = metaNodes.item(i) as Element
                if ((e.parentNode as? Element)?.tagName != "application") continue
                val name = e.android("name") ?: continue
                meta[name] = e.android("value").orEmpty()
            }
            val featureNodes = root.getElementsByTagName("uses-feature")
            for (i in 0 until featureNodes.length) {
                (featureNodes.item(i) as Element).android("name")?.let { features += it }
            }
            return ExtensionManifest(
                packageName = root.getAttribute("package"),
                versionName = root.android("versionName").orEmpty(),
                versionCode = root.android("versionCode")?.toLongOrNull() ?: 0,
                metaData = meta,
                features = features,
            )
        }

        private const val TYPE_FLOAT = 4

        /**
         * apksig exposes string, int and boolean values only; aapt2 compiles
         * `android:value="1.6"` (keiyoushi's extensionLib) as a float. Read the
         * typed value through apksig's internal attribute record (pinned version).
         */
        private fun rawTypedValue(parser: AndroidBinXmlParser, index: Int): String? = try {
            val getAttribute = AndroidBinXmlParser::class.java.getDeclaredMethod("getAttribute", Int::class.javaPrimitiveType)
            getAttribute.isAccessible = true
            val attribute = getAttribute.invoke(parser, index)
            val type = attribute.javaClass.getDeclaredField("mValueType").apply { isAccessible = true }.getInt(attribute)
            val data = attribute.javaClass.getDeclaredField("mValueData").apply { isAccessible = true }.getInt(attribute)
            if (type == TYPE_FLOAT) java.lang.Float.intBitsToFloat(data).toString() else null
        } catch (_: ReflectiveOperationException) {
            null
        }

        private fun parseBinary(bytes: ByteArray, label: String): ExtensionManifest {
            try {
                val parser = AndroidBinXmlParser(ByteBuffer.wrap(bytes))
                var packageName = ""
                var versionName = ""
                var versionCode = 0L
                val meta = LinkedHashMap<String, String>()
                val features = LinkedHashSet<String>()
                val path = ArrayList<String>()
                var event = parser.eventType
                while (event != AndroidBinXmlParser.EVENT_END_DOCUMENT) {
                    when (event) {
                        AndroidBinXmlParser.EVENT_START_ELEMENT -> {
                            val name = parser.name
                            val attrs = HashMap<String, String>()
                            for (i in 0 until parser.attributeCount) {
                                val attrName = parser.getAttributeName(i)
                                val value = when (parser.getAttributeValueType(i)) {
                                    AndroidBinXmlParser.VALUE_TYPE_STRING -> parser.getAttributeStringValue(i)
                                    AndroidBinXmlParser.VALUE_TYPE_INT, AndroidBinXmlParser.VALUE_TYPE_REFERENCE ->
                                        parser.getAttributeIntValue(i).toString()
                                    AndroidBinXmlParser.VALUE_TYPE_BOOLEAN -> parser.getAttributeBooleanValue(i).toString()
                                    else -> rawTypedValue(parser, i) ?: continue
                                }
                                attrs[attrName] = value
                            }
                            when {
                                name == "manifest" && path.isEmpty() -> {
                                    packageName = attrs["package"].orEmpty()
                                    versionName = attrs["versionName"].orEmpty()
                                    versionCode = attrs["versionCode"]?.toLongOrNull() ?: 0
                                }
                                name == "meta-data" && path.lastOrNull() == "application" -> {
                                    val key = attrs["name"]
                                    if (key != null) meta[key] = attrs["value"].orEmpty()
                                }
                                name == "uses-feature" -> attrs["name"]?.let { features += it }
                            }
                            path += name
                        }
                        AndroidBinXmlParser.EVENT_END_ELEMENT -> if (path.isNotEmpty()) path.removeAt(path.lastIndex)
                    }
                    event = parser.next()
                }
                return ExtensionManifest(packageName, versionName, versionCode, meta, features)
            } catch (e: ArtifactException) {
                throw e
            } catch (e: Exception) {
                throw ArtifactException("$label: unreadable binary AndroidManifest.xml: ${e.message}", e)
            }
        }
    }
}

