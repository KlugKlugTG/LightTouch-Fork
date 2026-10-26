package org.lighttouch.android

import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URI
import java.util.zip.GZIPInputStream
import org.apache.commons.compress.compressors.bzip2.BZip2CompressorInputStream
import org.tukaani.xz.XZInputStream
import org.tukaani.xz.LZMAInputStream

internal data class AptPackage(val fields: Map<String, String>, val source: String = "", val download: String = "") {
    val id get() = fields["Package"].orEmpty()
    val name get() = fields["Name"] ?: id
    val version get() = fields["Version"].orEmpty()
    val description get() = fields["Description"].orEmpty()
    val section get() = fields["Section"] ?: "Packages"
    val author get() = fields["Author"] ?: fields["Maintainer"].orEmpty()
    val architecture get() = fields["Architecture"].orEmpty()
    val installed get() = fields["Status"] == "install ok installed"
    val key get() = "$source|$id|$version"
}

internal object AptControl {
    fun parse(text: String): List<Map<String, String>> {
        val records = mutableListOf<Map<String, String>>()
        var record = linkedMapOf<String, String>(); var key = ""
        for (line in (text.replace("\r\n", "\n") + "\n\n").lineSequence()) {
            when {
                line.isEmpty() -> { if (record.isNotEmpty()) records += record; record = linkedMapOf(); key = "" }
                line.startsWith(' ') || line.startsWith('\t') -> if (key.isNotEmpty()) {
                    val value = line.drop(1); record[key] = record[key].orEmpty() + "\n" + if (value == ".") "" else value
                }
                ':' in line -> { key = line.substringBefore(':'); record[key] = line.substringAfter(':').trimStart() }
            }
        }
        return records
    }
}

/** dpkg's epoch/upstream/revision ordering (including tilde and numeric runs). */
internal object DebianVersion {
    fun compare(a: String, b: String): Int {
        fun split(s: String): Triple<Long, String, String> {
            val epoch = if (':' in s) s.substringBefore(':').toLongOrNull() ?: 0 else 0
            val body = if (':' in s) s.substringAfter(':') else s
            return Triple(epoch, if ('-' in body) body.substringBeforeLast('-') else body, if ('-' in body) body.substringAfterLast('-') else "0")
        }
        val x = split(a); val y = split(b)
        return x.first.compareTo(y.first).takeIf { it != 0 } ?: part(x.second, y.second).takeIf { it != 0 } ?: part(x.third, y.third)
    }
    private fun part(a: String, b: String): Int {
        var i = 0; var j = 0
        fun order(c: Char?) = when { c == '~' -> -1; c == null -> 0; c in 'A'..'Z' || c in 'a'..'z' -> c!!.code; else -> c!!.code + 256 }
        fun digit(c: Char?) = c != null && c in '0'..'9'
        while (i < a.length || j < b.length) {
            while ((i < a.length && !digit(a[i])) || (j < b.length && !digit(b[j]))) {
                val d = order(a.getOrNull(i).takeUnless { digit(it) }) - order(b.getOrNull(j).takeUnless { digit(it) })
                if (d != 0) return d
                if (i < a.length && !digit(a[i])) i++
                if (j < b.length && !digit(b[j])) j++
            }
            while (a.getOrNull(i) == '0') i++
            while (b.getOrNull(j) == '0') j++
            val ai = i; val bj = j
            while (digit(a.getOrNull(i))) i++
            while (digit(b.getOrNull(j))) j++
            val length = (i - ai).compareTo(j - bj)
            if (length != 0) return length
            val d = a.substring(ai, i).compareTo(b.substring(bj, j))
            if (d != 0) return d
        }
        return 0
    }
}

internal object AptDependencies {
    private val term = Regex("^([a-zA-Z0-9+._-]+)(?::[a-zA-Z0-9-]+)?\\s*(?:\\((<<|<=|=|>=|>>)\\s*([^()]+)\\))?$")
    data class Requirement(val id: String, val op: String, val version: String) {
        fun accepts(version: String): Boolean = when (op) {
            "=" -> DebianVersion.compare(version, this.version) == 0
            ">=" -> DebianVersion.compare(version, this.version) >= 0
            "<=" -> DebianVersion.compare(version, this.version) <= 0
            ">>" -> DebianVersion.compare(version, this.version) > 0
            "<<" -> DebianVersion.compare(version, this.version) < 0
            else -> true
        }
    }
    fun groups(text: String): List<List<Requirement>> = text.split(',').filter { it.isNotBlank() }.map { group ->
        group.split('|').map { raw ->
            val m = term.matchEntire(raw.trim()) ?: error("Unsupported dependency: ${raw.trim()}")
            Requirement(m.groupValues[1], m.groupValues[2], m.groupValues[3].trim())
        }
    }
    fun compatible(p: AptPackage, ios: String): String? {
        if (p.architecture !in listOf("iphoneos-arm", "all")) return "Architecture ${p.architecture} is not supported by this iOS device."
        val firmware = groups(p.fields["Depends"].orEmpty()).filter { it.all { r -> r.id == "firmware" } }
        if (firmware.any { it.none { r -> r.accepts(ios) } }) return "This package requires ${p.fields["Depends"]}; device has iOS $ios."
        return null
    }
    fun resolve(target: AptPackage, catalog: List<AptPackage>, installed: List<AptPackage>, ios: String): List<AptPackage> {
        val result = linkedMapOf<String, AptPackage>(); val visiting = mutableSetOf<String>()
        val present = installed.filter { it.installed }
        fun satisfies(p: AptPackage, r: Requirement): Boolean =
            (p.id == r.id && r.accepts(p.version)) || p.fields["Provides"].orEmpty().split(',').any { it.trim() == r.id && r.op.isEmpty() }
        fun visit(p: AptPackage) {
            compatible(p, ios)?.let { error(it) }
            if (result.containsKey(p.id)) return
            check(visiting.add(p.id)) { "Dependency cycle involving ${p.name}. Install its prerequisites with Cydia first." }
            for (group in groups(listOf(p.fields["Pre-Depends"], p.fields["Depends"]).filterNotNull().joinToString(","))) {
                if (group.any { r -> (r.id == "firmware" && r.accepts(ios)) || present.any { satisfies(it, r) } || result.values.any { satisfies(it, r) } }) continue
                val candidate = group.firstNotNullOfOrNull { r -> catalog.filter { it.download.isNotEmpty() && satisfies(it, r) && compatible(it, ios) == null }
                    .maxWithOrNull { a, b -> DebianVersion.compare(a.version, b.version) } }
                    ?: error("Missing dependency: ${group.joinToString(" | ") { it.id + if (it.op.isEmpty()) "" else " (${it.op} ${it.version})" }}. Add the source that provides it.")
                visit(candidate)
            }
            visiting.remove(p.id); result[p.id] = p
        }
        visit(target); return result.values.toList()
    }
}

internal object AptNetwork {
    const val INDEX_LIMIT = 64L shl 20
    fun decompress(input: InputStream, name: String): InputStream = when {
        name.endsWith(".gz") -> GZIPInputStream(input)
        name.endsWith(".bz2") -> BZip2CompressorInputStream(input)
        name.endsWith(".xz") -> XZInputStream(input, 65536)
        name.endsWith(".lzma") -> LZMAInputStream(input, 65536)
        name.endsWith(".zst") -> error("Zstandard packages are not supported by classic iOS dpkg.")
        else -> input
    }
    fun <T> fetch(address: String, read: (InputStream, Long, URI) -> T): T {
        var uri = DebArchive.address(address)
        for (attempt in 0..5) {
            val c = uri.toURL().openConnection() as HttpURLConnection
            try {
                c.connectTimeout = 15_000; c.readTimeout = 30_000; c.instanceFollowRedirects = false
                c.setRequestProperty("Accept-Encoding", "identity"); c.setRequestProperty("User-Agent", "Un1box-Cydia/1.0")
                if (c.responseCode in listOf(301, 302, 303, 307, 308)) {
                    val next = DebArchive.address(uri.resolve(c.getHeaderField("Location") ?: error("Empty redirect")).toString())
                    check(uri.scheme != "https" || next.scheme == "https") { "HTTPS source redirected to HTTP." }
                    uri = next
                } else {
                    check(c.responseCode == 200) { "${uri.host}: HTTP ${c.responseCode}" }
                    return c.inputStream.use { read(it, c.contentLengthLong, uri) }
                }
            } finally { c.disconnect() }
        }
        error("Too many redirects")
    }
    fun text(address: String): String = fetch(address) { input, size, uri ->
        check(size <= INDEX_LIMIT) { "Repository index is larger than 64 MB." }
        decompress(input, uri.path).use { stream ->
            val out = java.io.ByteArrayOutputStream(); val buffer = ByteArray(65536)
            while (true) { val count = stream.read(buffer); if (count < 0) break
                check(out.size().toLong() + count <= INDEX_LIMIT) { "Uncompressed repository index is larger than 64 MB." }; out.write(buffer, 0, count) }
            out.toString("UTF-8")
        }
    }
}
