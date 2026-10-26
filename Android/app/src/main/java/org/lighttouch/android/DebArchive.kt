package org.lighttouch.android

import java.io.File
import java.io.RandomAccessFile
import java.net.URI
import java.io.ByteArrayInputStream
import org.apache.commons.compress.archivers.tar.TarArchiveInputStream

/** Checks the Debian ar container without unpacking or executing a package. */
internal object DebArchive {
    const val LIMIT = 512L shl 20

    fun metadata(file: File): AptPackage {
        check(file)
        RandomAccessFile(file, "r").use { ar ->
            ar.seek(8)
            var control: ByteArray? = null; var controlName = ""
            while (ar.filePointer < ar.length()) {
                val header = ByteArray(60).also { ar.readFully(it) }
                val name = String(header, 0, 16, Charsets.US_ASCII).trim().removeSuffix("/")
                val size = String(header, 48, 10, Charsets.US_ASCII).trim().toLong()
                val end = ar.filePointer + size + size % 2
                require(name != "data.tar.zst" && name != "control.tar.zst") { "Zstandard .deb files require newer dpkg than classic iOS supports." }
                if (name.startsWith("control.tar")) {
                    require(size <= 4L shl 20) { "The package control archive is too large." }
                    control = ByteArray(size.toInt()).also { ar.readFully(it) }; controlName = name
                }
                ar.seek(end)
            }
            require(control != null) { "The package has no control archive." }
            AptNetwork.decompress(ByteArrayInputStream(control), controlName).use { compressed ->
                TarArchiveInputStream(compressed).use { tar ->
                    var total = 0L
                    while (true) {
                        val entry = tar.nextTarEntry ?: break
                        total += entry.size
                        require(total <= 8L shl 20) { "The uncompressed package control archive is too large." }
                        if (entry.name.removePrefix("./") == "control" && entry.isFile) {
                            require(entry.size in 1..(1L shl 20)) { "Invalid package metadata size." }
                            val bytes = ByteArray(entry.size.toInt()); var at = 0
                            while (at < bytes.size) { val n = tar.read(bytes, at, bytes.size - at); require(n > 0) { "Truncated package metadata." }; at += n }
                            val fields = AptControl.parse(bytes.toString(Charsets.UTF_8)).singleOrNull() ?: error("Invalid package control file.")
                            require(!fields["Package"].isNullOrBlank() && !fields["Version"].isNullOrBlank()) { "Missing package identity." }
                            return AptPackage(fields)
                        }
                    }
                }
            }
        }
        error("The package control file is missing.")
    }

    fun check(file: File) {
        require(file.length() in 8..LIMIT) { "The .deb is empty or larger than 512 MB." }
        RandomAccessFile(file, "r").use { archive ->
            val magic = ByteArray(8).also { archive.readFully(it) }
            require(magic.contentEquals("!<arch>\n".toByteArray(Charsets.US_ASCII))) { "This file is not a Debian .deb package." }
            val names = mutableSetOf<String>()
            while (archive.filePointer < archive.length()) {
                require(archive.length() - archive.filePointer >= 60) { "The .deb archive is truncated." }
                val header = ByteArray(60).also { archive.readFully(it) }
                require(header[58] == '`'.code.toByte() && header[59] == '\n'.code.toByte()) { "The .deb has an invalid archive header." }
                val name = String(header, 0, 16, Charsets.US_ASCII).trim().removeSuffix("/")
                val sizeText = String(header, 48, 10, Charsets.US_ASCII).trim()
                val size = sizeText.takeIf { it.isNotEmpty() && it.all { ch -> ch in '0'..'9' } }?.toLongOrNull()
                require(size != null && size > 0 && size <= archive.length() - archive.filePointer) { "The .deb has an invalid member size." }
                require(names.add(name)) { "The .deb has duplicate archive members." }
                require(names.size <= 32) { "The .deb has too many archive members." }
                val end = archive.filePointer + size
                if (names.size == 1) {
                    require(name == "debian-binary" && size == 4L) { "The .deb is missing its Debian format version." }
                    val version = ByteArray(4).also { archive.readFully(it) }
                    require(version.contentEquals("2.0\n".toByteArray(Charsets.US_ASCII))) { "This Debian package format is not supported." }
                }
                archive.seek(end)
                if (size % 2 != 0L) require(archive.read() == '\n'.code) { "The .deb has invalid archive padding." }
            }
            val extensions = listOf("", ".gz", ".xz", ".bz2", ".lzma", ".zst")
            require(names.count { it in extensions.map { suffix -> "control.tar$suffix" } } == 1 &&
                names.count { it in extensions.map { suffix -> "data.tar$suffix" } } == 1) {
                "The .deb is missing its control or data archive."
            }
        }
    }

    fun address(text: String): URI {
        val uri = try { URI(text.trim()) } catch (_: Exception) { throw IllegalArgumentException("Enter a valid .deb download link.") }
        require(uri.scheme?.lowercase() in listOf("http", "https") && !uri.host.isNullOrEmpty() &&
            uri.userInfo == null && uri.fragment == null && (uri.port == -1 || uri.port in 1..65535) && uri.toString().length <= 4096) {
            "Enter an HTTP or HTTPS link without a username, password or fragment."
        }
        return uri
    }

    fun name(raw: String): String {
        val basename = raw.substringAfterLast('/').substringAfterLast('\\')
        val stem = (if (basename.endsWith(".deb", ignoreCase = true)) basename.dropLast(4) else basename)
            .replace(Regex("[^A-Za-z0-9._-]"), "_").trim('.').take(80).ifEmpty { "package" }
        return "$stem.deb"
    }
}
