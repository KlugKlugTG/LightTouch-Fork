package org.lighttouch.android

import android.content.Context
import android.os.Handler
import android.os.Looper
import androidx.compose.runtime.*
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.URI
import java.security.MessageDigest

internal data class AptSource(val url: String, val suite: String = "", val component: String = "main",
    val label: String = URI(url).host, val count: Int = 0, val updated: Long = 0, val error: String = "")

/** Indexes and sources persist on Android; packages are transferred into the selected iOS guest. */
internal object CydiaSources {
    private val handler = Handler(Looper.getMainLooper())
    var sources by mutableStateOf<List<AptSource>>(emptyList()); private set
    var packages by mutableStateOf<List<AptPackage>>(emptyList()); private set
    var refreshing by mutableStateOf(false); private set
    var progress by mutableStateOf(""); private set
    var error by mutableStateOf(""); private set
    private var loaded = false

    private fun directory(c: Context) = File(c.filesDir, "cydia-sources").apply { mkdirs() }
    private fun cache(c: Context, s: AptSource) = File(directory(c), MessageDigest.getInstance("SHA-256")
        .digest("${s.url}|${s.suite}|${s.component}".toByteArray()).joinToString("") { "%02x".format(it) } + ".json")
    private fun sourceJson(s: AptSource) = JSONObject().put("url", s.url).put("suite", s.suite).put("component", s.component)
        .put("label", s.label).put("count", s.count).put("updated", s.updated).put("error", s.error)
    private fun write(file: File, text: String) {
        val part = File(file.parentFile, file.name + ".part"); part.writeText(text)
        check(part.renameTo(file)) { "Cannot save the repository cache." }
    }
    private fun persist(c: Context) = write(File(directory(c), "sources.json"), JSONArray().apply { sources.forEach { put(sourceJson(it)) } }.toString())
    fun load(c: Context) {
        if (loaded) return
        loaded = true
        sources = runCatching {
            val a = JSONArray(File(directory(c), "sources.json").readText())
            (0 until a.length()).map { a.getJSONObject(it).let { j -> AptSource(j.getString("url"), j.optString("suite"),
                j.optString("component", "main"), j.optString("label"), j.optInt("count"), j.optLong("updated"), j.optString("error")) } }
        }.getOrElse { listOf(AptSource("http://apt.saurik.com/", "ios/675.00", "main", "Cydia/Telesphoreo"),
            AptSource("https://cydia.invoxiplaygames.uk/", label = "InvoxiPlayGames"),
            AptSource("http://apt.thebigboss.org/repofiles/cydia/", "stable", "main", "BigBoss")) }
        packages = sources.flatMap { readCache(c, it) }
    }
    private fun readCache(c: Context, s: AptSource): List<AptPackage> = runCatching {
        val a = JSONArray(cache(c, s).readText())
        (0 until a.length()).map { a.getJSONObject(it).let { j ->
            val f = j.getJSONObject("fields"); AptPackage(f.keys().asSequence().associateWith { f.getString(it) }, s.url, j.getString("download"))
        } }
    }.getOrDefault(emptyList())
    fun add(c: Context, raw: String, suite: String, component: String) {
        if (refreshing) return
        try {
            val uri = DebArchive.address(raw)
            require(uri.query == null) { "A repository address cannot contain a query." }
            require(suite.isBlank() || suite.matches(Regex("[A-Za-z0-9._/-]+")) && !suite.split('/').contains("..")) { "Invalid distribution." }
            require(component.isBlank() || component.matches(Regex("[A-Za-z0-9._-]+"))) { "Invalid component." }
            val url = uri.toString().trimEnd('/') + "/"
            require(sources.none { it.url == url }) { "This source is already added." }
            sources = sources + AptSource(url, suite.trim(), component.trim().ifEmpty { "main" }); persist(c); error = ""
            refresh(c, url)
        } catch (e: Exception) { error = e.message.orEmpty() }
    }
    fun remove(c: Context, s: AptSource) {
        if (refreshing) return
        sources = sources.filter { it.url != s.url }; packages = packages.filter { it.source != s.url }
        cache(c, s).delete(); persist(c)
    }
    fun refresh(c: Context, only: String? = null) {
        if (refreshing) return
        val app = c.applicationContext; load(app)
        refreshing = true; error = ""; progress = "Refreshing sources"
        val snapshot = sources
        Thread({
            val results = snapshot.filter { only == null || it.url == only }.map { s ->
                handler.post { progress = "Refreshing ${s.label}" }
                val attempt = runCatching { fetch(s) }
                attempt.fold(onSuccess = { (label, list) ->
                    runCatching { write(cache(app, s), JSONArray().apply { list.forEach { put(JSONObject().put("fields", JSONObject(it.fields)).put("download", it.download)) } }.toString()) }
                        .fold({ s.copy(label = label, count = list.size, updated = System.currentTimeMillis(), error = "") to list },
                            { s.copy(error = it.message.orEmpty()) to readCache(app, s) })
                }, onFailure = { s.copy(error = it.message ?: "Source unavailable") to readCache(app, s) })
            }
            handler.post {
                sources = snapshot.map { s -> results.find { it.first.url == s.url }?.first ?: s }
                packages = snapshot.flatMap { s -> results.find { it.first.url == s.url }?.second ?: packages.filter { it.source == s.url } }
                runCatching { persist(app) }.onFailure { error = it.message.orEmpty() }
                refreshing = false; progress = ""
            }
        }, "cydia-sources").start()
    }
    private fun fetch(s: AptSource): Pair<String, List<AptPackage>> {
        val base = URI(s.url)
        val release = runCatching { AptControl.parse(AptNetwork.text(base.resolve(if (s.suite.isBlank()) "Release" else "dists/${s.suite}/Release").toString())).firstOrNull() }.getOrNull()
        val roots = if (s.suite.isBlank()) listOf("", "dists/${release?.get("Suite") ?: "stable"}/${s.component}/binary-iphoneos-arm/")
            else listOf("dists/${s.suite}/${s.component}/binary-iphoneos-arm/", "")
        var last = "No Packages index found"
        for (root in roots) for (suffix in listOf(".gz", ".bz2", ".xz", "")) {
            try {
                val text = AptNetwork.text(base.resolve(root + "Packages" + suffix).toString())
                val list = AptControl.parse(text).filter { it["Package"]?.isNotBlank() == true && it["Version"]?.isNotBlank() == true && it["Filename"]?.isNotBlank() == true }
                    .mapNotNull { fields -> runCatching { AptPackage(fields, s.url, DebArchive.address(base.resolve(fields.getValue("Filename")).toString()).toString()) }.getOrNull() }
                    .filter { it.architecture in listOf("iphoneos-arm", "all") }
                check(list.isNotEmpty()) { "The index contains no classic iOS packages." }
                return (release?.get("Label") ?: release?.get("Origin") ?: s.label) to list
            } catch (e: Exception) { last = e.message.orEmpty() }
        }
        error(last)
    }
    fun latest(): List<AptPackage> = packages.groupBy { it.id }.values.map { group -> group.maxWith { a, b -> DebianVersion.compare(a.version, b.version) } }
}
