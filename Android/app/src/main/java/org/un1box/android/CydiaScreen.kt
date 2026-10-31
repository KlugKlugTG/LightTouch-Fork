package org.un1box.android

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import java.text.DateFormat
import java.util.Date

private enum class CydiaTab(val title: String, val icon: ImageVector) {
    HOME("Cydia", LtIcons.Package), SOURCES("Sources", LtIcons.Layers), CHANGES("Changes", LtIcons.History),
    INSTALLED("Installed", LtIcons.Download), SEARCH("Search", Icons.Filled.Search)
}

@OptIn(androidx.compose.ui.ExperimentalComposeUiApi::class)
@Composable
internal fun CydiaScreen(device: DeviceSummary?, socket: String?, blocked: Boolean, onPickLocal: () -> Unit, onBack: () -> Unit) {
    val context = LocalContext.current
    var tabName by rememberSaveable(device?.id) { mutableStateOf("HOME") }
    var chosen by remember { mutableStateOf<AptPackage?>(null) }
    var sourceUrl by rememberSaveable { mutableStateOf<String?>(null) }
    var query by rememberSaveable { mutableStateOf("") }
    var section by rememberSaveable { mutableStateOf<String?>(null) }
    var filesVisible by rememberSaveable { mutableStateOf(false) }
    var dialog by rememberSaveable { mutableStateOf("") }
    var link by rememberSaveable { mutableStateOf("") }
    var sourceInput by rememberSaveable { mutableStateOf("") }
    var suite by rememberSaveable { mutableStateOf("") }
    var component by rememberSaveable { mutableStateOf("main") }
    val tab = CydiaTab.valueOf(tabName)
    val connected = socket != null && !blocked
    val canInstall = connected && !CydiaTransfers.active && GuestApps(context).available
    val colors = MaterialTheme.colorScheme
    val accent = Color(0xFF3478C9)
    val source = CydiaSources.sources.find { it.url == sourceUrl }
    LaunchedEffect(device?.id, socket) { CydiaSources.load(context); CydiaTransfers.refresh(context, socket) }
    val goBack: () -> Unit = {
        when { chosen != null -> chosen = null; filesVisible -> filesVisible = false; section != null -> section = null
            sourceUrl != null -> sourceUrl = null; tab != CydiaTab.HOME -> tabName = "HOME"; else -> onBack() }
    }
    BackHandler(onBack = goBack)
    if (dialog.isNotEmpty()) AlertDialog(onDismissRequest = { dialog = "" }, modifier = DialogTags,
        title = { Text(when (dialog) { "add" -> "Add Source"; "remove" -> "Remove ${source?.label}?"; else -> "Install from URL" }) },
        text = { Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            when (dialog) {
                "add" -> {
                    OutlinedTextField(sourceInput, { sourceInput = it }, label = { Text("Repository URL") }, singleLine = true, modifier = Modifier.testTag("cydia_source_url"))
                    Text("For Cydia sources, leave Distribution empty. Debian sources use a distribution and component.", style = MaterialTheme.typography.bodySmall)
                    OutlinedTextField(suite, { suite = it }, label = { Text("Distribution (optional)") }, singleLine = true)
                    OutlinedTextField(component, { component = it }, label = { Text("Component") }, singleLine = true)
                }
                "remove" -> Text(source?.url.orEmpty())
                else -> {
                    Text("Download the .deb and install it in iOS. Dependencies are resolved from your sources.", style = MaterialTheme.typography.bodyMedium)
                    OutlinedTextField(link, { link = it }, label = { Text("Direct .deb URL") }, singleLine = true, modifier = Modifier.testTag("cydia_deb_url"))
                }
            }
        } }, confirmButton = { TextButton(onClick = {
            when (dialog) {
                "add" -> CydiaSources.add(context, sourceInput, suite, component)
                "remove" -> source?.let { CydiaSources.remove(context, it); sourceUrl = null }
                else -> socket?.let { CydiaTransfers.download(context, it, link) }
            }; dialog = ""
        }, enabled = when (dialog) { "add" -> sourceInput.isNotBlank(); "remove" -> true; else -> canInstall && runCatching { DebArchive.address(link) }.isSuccess },
            modifier = Modifier.testTag(if (dialog == "add") "cydia_add_source_confirm" else "cydia_confirm_download")) {
            Text(when (dialog) { "add" -> "Add Source"; "remove" -> "Remove"; else -> "Install" })
        } }, dismissButton = { TextButton(onClick = { dialog = "" }) { Text("Cancel") } })

    Surface(Modifier.fillMaxSize().testTag("cydia_screen").semantics { testTagsAsResourceId = true }, color = colors.surfaceContainerLow) {
        Column(Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.safeDrawing).imePadding()) {
            Row(Modifier.fillMaxWidth().background(colors.surface).height(56.dp), verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = goBack, modifier = Modifier.testTag("cydia_back")) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back", tint = accent) }
                Text(chosen?.name ?: if (filesVisible) "Package Files" else source?.label ?: tab.title, Modifier.weight(1f),
                    style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                if (chosen != null && chosen!!.download.isNotEmpty()) TextButton(onClick = { socket?.let { CydiaTransfers.installPackage(context, it, chosen!!) } },
                    enabled = canInstall, modifier = Modifier.testTag("cydia_install_package")) { Text("Install") }
                else if (tab == CydiaTab.SOURCES && chosen == null && !filesVisible) TextButton(onClick = { dialog = if (source != null) "remove" else "add" },
                    enabled = !CydiaSources.refreshing) { Text(if (source != null) "Remove" else "Add", color = accent) }
                else TextButton(onClick = { CydiaSources.refresh(context); if (connected) CydiaTransfers.refresh(context, socket) },
                    enabled = !CydiaSources.refreshing && !CydiaTransfers.active) { Text("Refresh", color = accent) }
            }
            HorizontalDivider()
            if (CydiaSources.refreshing) { LinearProgressIndicator(Modifier.fillMaxWidth()); Text(CydiaSources.progress, Modifier.padding(8.dp), style = MaterialTheme.typography.bodySmall) }
            if (CydiaSources.error.isNotEmpty()) Text(CydiaSources.error, Modifier.padding(12.dp), color = colors.error)
            CydiaTransfers.job?.let { TransferPanel(it) }
            Box(Modifier.weight(1f)) {
                when {
                    chosen != null -> PackageDetails(chosen!!, CydiaTransfers.installed.find { it.id == chosen!!.id }, device?.target?.ios)
                    filesVisible -> PackageFiles(canInstall, { CydiaTransfers.refresh(context, socket) }) { f -> socket?.let { CydiaTransfers.installFile(context, it, f) } }
                    tab == CydiaTab.HOME -> LazyColumn(contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(20.dp)) {
                        item { Group {
                            Row(Modifier.padding(20.dp), verticalAlignment = Alignment.CenterVertically) {
                                PackageIcon(LtIcons.Package, Color(0xFF9B6C43), 58)
                                Column(Modifier.padding(start = 16.dp)) {
                                    Text("Welcome to Cydia", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
                                    Text(device?.subtitle ?: "Select an iOS device", style = MaterialTheme.typography.bodySmall, color = colors.onSurfaceVariant)
                                }
                            }
                            HorizontalDivider(); Text("${CydiaSources.sources.size} sources · ${CydiaSources.latest().size} packages", Modifier.padding(16.dp))
                        } }
                        item { Label("PACKAGES"); Group {
                            ActionRow("Sources", "Manage repositories and browse packages", LtIcons.Layers) { tabName = "SOURCES" }
                            HorizontalDivider(Modifier.padding(start = 60.dp))
                            ActionRow("Installed", "${CydiaTransfers.installed.size} packages in iOS", LtIcons.Download) { tabName = "INSTALLED" }
                            HorizontalDivider(Modifier.padding(start = 60.dp))
                            ActionRow("Package Files", "Saved .deb files in iOS", LtIcons.File) { filesVisible = true }
                        } }
                        item { Label("INSTALL A PACKAGE"); Group {
                            ActionRow("Import .deb", "Choose your file and install it in iOS", LtIcons.Folder, canInstall, "cydia_import_deb", onPickLocal)
                            HorizontalDivider(Modifier.padding(start = 60.dp))
                            ActionRow("Install from URL", "Download a .deb and install it in iOS", LtIcons.Download, canInstall, "cydia_download_deb") { dialog = "download" }
                        }
                            Text(if (!connected) "Start iOS to install packages and read the device's package list." else CydiaTransfers.installerMessage,
                                Modifier.padding(top = 10.dp), style = MaterialTheme.typography.bodySmall, color = colors.onSurfaceVariant)
                        }
                    }
                    tab == CydiaTab.SOURCES && source == null -> LazyColumn(contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        item { Row(verticalAlignment = Alignment.CenterVertically) {
                            Text("SOURCES", Modifier.weight(1f), style = MaterialTheme.typography.labelMedium)
                            TextButton(onClick = { CydiaSources.refresh(context) }, enabled = !CydiaSources.refreshing, modifier = Modifier.testTag("cydia_refresh_sources")) { Text("Refresh") }
                        } }
                        items(CydiaSources.sources, key = { it.url }) { s -> Group {
                            ActionRow(s.label, s.url, LtIcons.Layers) { sourceUrl = s.url }
                            Text(if (s.error.isNotEmpty()) s.error else if (s.updated == 0L) "Refresh to load packages" else "${s.count} packages · ${DateFormat.getDateTimeInstance(DateFormat.SHORT, DateFormat.SHORT).format(Date(s.updated))}",
                                Modifier.padding(start = 60.dp, end = 16.dp, bottom = 14.dp), color = if (s.error.isNotEmpty()) colors.error else colors.onSurfaceVariant, style = MaterialTheme.typography.bodySmall)
                        } }
                        item { OutlinedButton(onClick = { dialog = "add" }, enabled = !CydiaSources.refreshing, modifier = Modifier.fillMaxWidth().testTag("cydia_add_source")) { Text("Add Source") } }
                    }
                    source != null && section == null -> {
                        val packages = CydiaSources.latest().filter { it.source == source.url }
                        val sections = packages.groupingBy { it.section }.eachCount().toSortedMap()
                        LazyColumn(contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            if (source.error.isNotEmpty()) item { Text(source.error, color = colors.error) }
                            item { Group { ActionRow("All Packages", "${packages.size} packages", LtIcons.Package) { section = "" } } }
                            items(sections.entries.toList(), key = { it.key }) { e -> Group { ActionRow(e.key, "${e.value} packages", LtIcons.Folder) { section = e.key } } }
                        }
                    }
                    else -> Column {
                        if (tab == CydiaTab.SEARCH) OutlinedTextField(query, { query = it }, placeholder = { Text("Package name or description") },
                            singleLine = true, leadingIcon = { Icon(Icons.Filled.Search, null) }, modifier = Modifier.fillMaxWidth().padding(12.dp).testTag("cydia_search"))
                        val list = when (tab) {
                            CydiaTab.INSTALLED -> CydiaTransfers.installed
                            CydiaTab.CHANGES -> CydiaSources.latest().filter { p -> CydiaTransfers.installed.any { it.id == p.id && DebianVersion.compare(p.version, it.version) > 0 } }
                            else -> CydiaSources.latest().filter { p -> (source == null || p.source == source.url) &&
                                (section.isNullOrEmpty() || p.section == section) && (tab != CydiaTab.SEARCH || query.isBlank() || listOf(p.name, p.id, p.description, p.author).any { it.contains(query.trim(), true) }) }
                        }.sortedBy { it.name.lowercase() }
                        if (tab == CydiaTab.INSTALLED && CydiaTransfers.loading) LinearProgressIndicator(Modifier.fillMaxWidth())
                        if (tab == CydiaTab.INSTALLED && CydiaTransfers.installerMessage.isNotEmpty()) Text(CydiaTransfers.installerMessage, Modifier.padding(16.dp), color = colors.error)
                        if (list.isEmpty()) EmptyState(if (tab == CydiaTab.CHANGES) "No updates available" else "No packages to show",
                            if (tab == CydiaTab.CHANGES) "Refresh sources to check installed packages for newer versions." else "Add a source and refresh its package list.")
                        else LazyColumn(Modifier.weight(1f), contentPadding = PaddingValues(vertical = 8.dp)) {
                            items(list, key = { it.key }) { p -> PackageRow(p, CydiaTransfers.installed.any { it.id == p.id }) { chosen = p } }
                        }
                    }
                }
            }
            HorizontalDivider()
            Row(Modifier.fillMaxWidth().background(colors.surface).height(64.dp)) {
                CydiaTab.entries.forEach { t -> Column(Modifier.weight(1f).fillMaxHeight().clickable {
                    tabName = t.name; chosen = null; sourceUrl = null; section = null; filesVisible = false
                }.testTag("cydia_tab_${t.name.lowercase()}"), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
                    Icon(t.icon, t.title, Modifier.size(24.dp), tint = if (tab == t) accent else colors.onSurfaceVariant)
                    Text(t.title, Modifier.padding(top = 4.dp), style = MaterialTheme.typography.labelSmall, color = if (tab == t) accent else colors.onSurfaceVariant)
                } }
            }
        }
    }
}

@Composable private fun Group(modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) {
    Surface(modifier.fillMaxWidth(), shape = RoundedCornerShape(10.dp), color = MaterialTheme.colorScheme.surface) { Column(content = content) }
}
@Composable private fun Label(text: String) { Text(text, Modifier.padding(start = 14.dp, bottom = 8.dp), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant) }
@Composable private fun PackageIcon(icon: ImageVector, color: Color = Color(0xFF8C9BAA), size: Int = 38) {
    Surface(Modifier.size(size.dp), color = color, shape = RoundedCornerShape(8.dp)) { Box(contentAlignment = Alignment.Center) { Icon(icon, null, Modifier.size((size * .6f).dp), tint = Color.White) } }
}
@Composable private fun ActionRow(title: String, subtitle: String, icon: ImageVector, enabled: Boolean = true, tag: String = "", onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().clickable(enabled = enabled, onClick = onClick).testTag(tag).padding(14.dp), verticalAlignment = Alignment.CenterVertically) {
        PackageIcon(icon)
        Column(Modifier.weight(1f).padding(horizontal = 12.dp)) {
            Text(title, style = MaterialTheme.typography.bodyLarge, color = if (enabled) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurfaceVariant)
            if (subtitle.isNotBlank()) Text(subtitle, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
        Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}
@Composable private fun PackageRow(p: AptPackage, installed: Boolean, onClick: () -> Unit) {
    Column(Modifier.background(MaterialTheme.colorScheme.surface)) {
        ActionRow(p.name, "${p.version}${if (installed) " · Installed" else ""}\n${p.description.substringBefore('\n')}", if (p.section.contains("Theme")) LtIcons.Palette else LtIcons.Package, onClick = onClick)
        HorizontalDivider(Modifier.padding(start = 64.dp))
    }
}
@Composable private fun PackageDetails(p: AptPackage, installed: AptPackage?, ios: String?) {
    LazyColumn(contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
        item { Group { Row(Modifier.padding(20.dp), verticalAlignment = Alignment.CenterVertically) {
            PackageIcon(LtIcons.Package, Color(0xFF9B6C43), 58)
            Column(Modifier.padding(start = 16.dp)) { Text(p.name, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold); Text(p.version, color = MaterialTheme.colorScheme.onSurfaceVariant) }
        } } }
        item { Group { Text(p.description.ifBlank { "No description provided." }, Modifier.padding(16.dp), style = MaterialTheme.typography.bodyMedium) } }
        if (ios != null) runCatching { AptDependencies.compatible(p, ios) }.getOrNull()?.let { reason -> item { Text(reason, color = MaterialTheme.colorScheme.error) } }
        item { Label("INFORMATION"); Group {
            listOf("Package" to p.id, "Version" to p.version, "Installed" to installed?.version.orEmpty(), "Section" to p.section,
                "Author" to p.author, "Architecture" to p.architecture, "Source" to p.source,
                "Size" to p.fields["Size"]?.toLongOrNull()?.let(::byteSize).orEmpty(), "Depends" to p.fields["Depends"].orEmpty())
                .filter { it.second.isNotEmpty() }.forEach { (key, value) -> Row(Modifier.padding(14.dp)) {
                    Text(key, Modifier.width(100.dp), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Text(value, Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
                }; HorizontalDivider() }
        } }
    }
}
@Composable private fun EmptyState(title: String, text: String) {
    Column(Modifier.fillMaxWidth().padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Icon(LtIcons.Package, null, Modifier.size(40.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(title, Modifier.padding(top = 16.dp), style = MaterialTheme.typography.titleMedium)
        Text(text, Modifier.padding(top = 8.dp), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}
@Composable private fun TransferPanel(job: CydiaTransferJob) {
    var expanded by remember(job.error) { mutableStateOf(false) }
    Surface(Modifier.fillMaxWidth(), color = if (job.error != null) MaterialTheme.colorScheme.errorContainer else MaterialTheme.colorScheme.secondaryContainer) {
        Column(Modifier.padding(14.dp)) {
            Text(job.name, style = MaterialTheme.typography.titleSmall)
            Text(job.error ?: job.phase, style = MaterialTheme.typography.bodySmall, maxLines = if (expanded) Int.MAX_VALUE else 3, overflow = TextOverflow.Ellipsis)
            if (CydiaTransfers.active) if (job.progress == null) LinearProgressIndicator(Modifier.fillMaxWidth().padding(top = 8.dp)) else LinearProgressIndicator(progress = { job.progress }, modifier = Modifier.fillMaxWidth().padding(top = 8.dp))
            Row {
                if (job.error != null) TextButton(onClick = { expanded = !expanded }) { Text(if (expanded) "Hide log" else "Show log") }
                if (CydiaTransfers.active && job.cancellable) TextButton(onClick = CydiaTransfers::cancel) { Text("Cancel") }
                if (!CydiaTransfers.active) TextButton(onClick = CydiaTransfers::dismissJob) { Text("Dismiss") }
            }
        }
    }
}
@Composable private fun PackageFiles(canInstall: Boolean, refresh: () -> Unit, install: (GuestDeb) -> Unit) {
    Column {
        Row(Modifier.padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
            Text("Saved in iOS", Modifier.weight(1f), style = MaterialTheme.typography.titleSmall)
            TextButton(onClick = refresh, enabled = !CydiaTransfers.loading && !CydiaTransfers.active) { Text("Refresh") }
        }
        if (CydiaTransfers.loading) LinearProgressIndicator(Modifier.fillMaxWidth())
        if (CydiaTransfers.message.isNotEmpty()) Text(CydiaTransfers.message, Modifier.padding(16.dp), color = MaterialTheme.colorScheme.error)
        LazyColumn(contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            items(CydiaTransfers.files, key = { it.path }) { f -> Group {
                Text(f.name, Modifier.padding(14.dp), style = MaterialTheme.typography.bodyMedium)
                Text("${byteSize(f.bytes)} · ${f.path}", Modifier.padding(horizontal = 14.dp), style = MaterialTheme.typography.bodySmall)
                TextButton(onClick = { install(f) }, enabled = canInstall, modifier = Modifier.align(Alignment.End).testTag("cydia_install_saved")) { Text("Install") }
            } }
        }
    }
}
