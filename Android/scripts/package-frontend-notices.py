#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Package original selected AAR/JAR notices; never infer a license grant."""
import argparse
from collections import Counter
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import stat
import tempfile
from urllib.parse import urljoin, urlsplit
import xml.etree.ElementTree as ET
import zipfile

MAX_NOTICE = 4 * 1024 * 1024
MAX_NESTED_JAR = 96 * 1024 * 1024
NOTICE_NAME = re.compile(r"(^|/)(licen[cs]es?|notices?|copying|copyrights?|authors|third[-_]?party[-_]?notices?)([^/]*$|/)", re.I)
SAFE_PART = re.compile(r"[A-Za-z0-9._-]+")
HASH = re.compile(r"[0-9a-f]{64}")

# Public, versioned source inputs. Gitiles files are hashed after base64 decoding.
PINNED_UPSTREAM_TEXTS = {
    'Annotations-23.0.0-LICENSE.txt': ('https://raw.githubusercontent.com/JetBrains/java-annotations/23.0.0/LICENSE.txt', '8c1e966c7855fb54027bcaf6ebe7a43abe4785791e8cf9148c363761d493d097'),
    'Apache-LICENSE-2.0.txt': ('https://www.apache.org/licenses/LICENSE-2.0.txt', 'cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30'),
    'Coroutines-1.7.3-LICENSE.txt': ('https://raw.githubusercontent.com/Kotlin/kotlinx.coroutines/1.7.3/LICENSE.txt', 'b1febe6399dffb10d19d35e7663ab16300c93cb0476a94115df1cc0097a8ffd8'),
    'GraphicsPath-1.0.1-Conic.cpp': ('https://android.googlesource.com/platform/frameworks/support/+/8a05a22af450d589ef911d772a001a49dcb05b71/graphics/graphics-path/src/main/cpp/Conic.cpp?format=TEXT', '49b3da93aa43480cf9cd481590be48705cb9340c52e5d09635efbd0ece07be83'),
    'GraphicsPath-1.0.1-Conic.h': ('https://android.googlesource.com/platform/frameworks/support/+/8a05a22af450d589ef911d772a001a49dcb05b71/graphics/graphics-path/src/main/cpp/Conic.h?format=TEXT', 'cd315ad7c8d030c72e96893e9a0feec463d72d2066209a203dedcf0925398a6f'),
    'GraphicsPath-1.0.1-Path.h': ('https://android.googlesource.com/platform/frameworks/support/+/8a05a22af450d589ef911d772a001a49dcb05b71/graphics/graphics-path/src/main/cpp/Path.h?format=TEXT', '4ee841338063d8c6f71ff4c655ecf52559f6c6df9af79835388dae1ebcd8b982'),
    'GraphicsPath-1.0.1-PathIterator.cpp': ('https://android.googlesource.com/platform/frameworks/support/+/8a05a22af450d589ef911d772a001a49dcb05b71/graphics/graphics-path/src/main/cpp/PathIterator.cpp?format=TEXT', '3705946b43bf894e013f46ccc940f9923f43285340f8fc2128f95c59238ec7f8'),
    'GraphicsPath-1.0.1-PathIterator.h': ('https://android.googlesource.com/platform/frameworks/support/+/8a05a22af450d589ef911d772a001a49dcb05b71/graphics/graphics-path/src/main/cpp/PathIterator.h?format=TEXT', 'a16e99b0273fb7205607eb0cf51fc7be518a55f3446a304f92ecab353e77be6f'),
    'GraphicsPath-1.0.1-math-TVecHelpers.h': ('https://android.googlesource.com/platform/frameworks/support/+/8a05a22af450d589ef911d772a001a49dcb05b71/graphics/graphics-path/src/main/cpp/math/TVecHelpers.h?format=TEXT', '1b0d6b06c5bbd6b438f9d8440ac78cf93fb8a713761badc59a4412b6457c1014'),
    'GraphicsPath-1.0.1-math-compiler.h': ('https://android.googlesource.com/platform/frameworks/support/+/8a05a22af450d589ef911d772a001a49dcb05b71/graphics/graphics-path/src/main/cpp/math/compiler.h?format=TEXT', 'd53e85383580e5dbf81cbcb24426b0fe1bf419b4837540242dbdca3f1df4cf66'),
    'GraphicsPath-1.0.1-math-vec2.h': ('https://android.googlesource.com/platform/frameworks/support/+/8a05a22af450d589ef911d772a001a49dcb05b71/graphics/graphics-path/src/main/cpp/math/vec2.h?format=TEXT', '09e1a8eb3f8fdf9c1071500f1a4933f67caeb6d0f765d5c44ba968370de9fcb1'),
    'GraphicsPath-1.0.1-pathway.cpp': ('https://android.googlesource.com/platform/frameworks/support/+/8a05a22af450d589ef911d772a001a49dcb05b71/graphics/graphics-path/src/main/cpp/pathway.cpp?format=TEXT', '4be68d6fdb6376e95560f7c49a79aa0cd97218d758cf11ea3230ac9124485800'),
    'GraphicsPath-1.0.1-scalar.h': ('https://android.googlesource.com/platform/frameworks/support/+/8a05a22af450d589ef911d772a001a49dcb05b71/graphics/graphics-path/src/main/cpp/scalar.h?format=TEXT', 'b1d2bba80a4c9272d84473b6f09f700972b016f7579842d3a87bdbbdb2af1edc'),
    'Kotlin-1.8.20-LICENSE.txt': ('https://raw.githubusercontent.com/JetBrains/kotlin/v1.8.20/license/LICENSE.txt', 'cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30'),
    'Kotlin-2.1.20-LICENSE.txt': ('https://raw.githubusercontent.com/JetBrains/kotlin/v2.1.20/license/LICENSE.txt', 'cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30'),
    'Kotlin-2.1.20-boost_LICENSE.txt': ('https://raw.githubusercontent.com/JetBrains/kotlin/v2.1.20/license/third_party/boost_LICENSE.txt', '8d8291caf1cee26d23acf3eb67c9f9a2d58f1c681b16a4fbe8cbfb9e3c0b5a9b'),
    'Kotlin-2.1.20-guava_license.txt': ('https://raw.githubusercontent.com/JetBrains/kotlin/v2.1.20/license/third_party/guava_license.txt', 'cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30'),
    'Kotlin-2.1.20-gwt_license.txt': ('https://raw.githubusercontent.com/JetBrains/kotlin/v2.1.20/license/third_party/gwt_license.txt', 'cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30'),
    'Kotlin-2.1.20-license-README.md': ('https://raw.githubusercontent.com/JetBrains/kotlin/v2.1.20/license/README.md', '7b9ed2fce6cb756174326571ef57e641e7b22c439c87ee7e2ab85e9be9751d95'),
    'Kotlin-2.1.20-threetenbp_license.txt': ('https://raw.githubusercontent.com/JetBrains/kotlin/v2.1.20/license/third_party/threetenbp_license.txt', 'd1bc53b493a3ab387b42717ed5c4b1976a5048996f81154278100bff86d39331'),
}


def sha(data):
    return hashlib.sha256(data).hexdigest()


def encoded(document):
    return (json.dumps(document, indent=2, ensure_ascii=True, sort_keys=True) + "\n").encode()


def https(url):
    p = urlsplit(url)
    if not url.startswith("https://") or p.scheme != "https" or not p.netloc or p.username or p.password:
        raise ValueError("Expected HTTPS provenance URL without credentials")
    return url


def coordinate(value):
    parts = value.split(":")
    if len(parts) != 3 or any(not SAFE_PART.fullmatch(p) or p in (".", "..") for p in parts):
        raise ValueError("Invalid Maven coordinate")
    return parts


def artifact_base(parts):
    group, module, version = parts
    repository = "https://dl.google.com/dl/android/maven2/" if group.startswith("androidx.") else "https://repo.maven.apache.org/maven2/"
    return repository + group.replace(".", "/") + "/" + module + "/" + version + "/"


def archive_notices(data, prefix="", depth=0):
    """Read members without extracting their original paths to the filesystem."""
    found, native = [], []
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        entries = archive.infolist()
        if len(entries) > 50000 or len({i.filename for i in entries}) != len(entries):
            raise ValueError("Too many or duplicate ZIP entries")
        for member in sorted(entries, key=lambda i: i.filename):
            if member.is_dir():
                continue
            name = prefix + member.filename
            is_jar = member.filename.lower().endswith(".jar")
            is_notice = NOTICE_NAME.search(member.filename) is not None and not member.filename.lower().endswith((".class", ".so", ".dex", ".jar"))
            if is_notice or is_jar:
                if stat.S_ISLNK(member.external_attr >> 16):
                    raise ValueError("Symlink notice or nested archive")
                maximum = MAX_NESTED_JAR if is_jar else MAX_NOTICE
                if member.file_size > maximum:
                    raise ValueError("Notice or nested archive exceeds bound")
                value = archive.read(member)
                if is_notice:
                    found.append((name, value))
                if is_jar:
                    if depth >= 3:
                        raise ValueError("Nested JAR depth exceeds bound")
                    child, libs = archive_notices(value, name + "!/", depth + 1)
                    found.extend(child)
                    native.extend(libs)
            if member.filename.lower().endswith(".so"):
                native.append({"archive_entry": name, "sha256": sha(archive.read(member)), "size": member.file_size})
    return found, native


def metadata(cache, parts, artifact):
    """Retain exact selected-version metadata, never the whole download cache."""
    root = cache.joinpath(*parts)
    base = artifact_base(parts)
    result = {"artifact_source_url": base + artifact["file"], "artifact_url_basis": "coordinate-derived repository locator"}
    payloads = []
    for suffix in ("pom", "module"):
        candidates = sorted(root.glob("*/*." + suffix))
        candidates = [p for p in candidates if p.name == parts[1] + "-" + parts[2] + "." + suffix]
        values = {sha(p.read_bytes()): p.read_bytes() for p in candidates}
        if len(values) > 1:
            raise ValueError("Conflicting cached metadata for " + ":".join(parts))
        if not values:
            continue
        digest, data = next(iter(values.items()))
        result[suffix + "_sha256"] = digest
        result[suffix + "_source_url"] = base + parts[1] + "-" + parts[2] + "." + suffix
        if suffix == "pom":
            xml = ET.fromstring(data)
            ns = "{http://maven.apache.org/POM/4.0.0}"
            resolved = [xml.findtext(ns + field) or xml.findtext(ns + "parent/" + ns + field) or ""
                        for field in ("groupId", "artifactId", "version")]
            if resolved != parts:
                raise ValueError("POM coordinate does not match selected artifact: " + ":".join(parts))
            result["declared_licenses"] = [{"name": node.findtext(ns + "name") or "", "url": node.findtext(ns + "url") or ""}
                                           for node in xml.findall(ns + "licenses/" + ns + "license")]
            result["upstream_project_url"] = xml.findtext(ns + "url") or ""
            result["upstream_scm_url"] = xml.findtext(ns + "scm/" + ns + "url") or ""
            result["upstream_organization"] = xml.findtext(ns + "organization/" + ns + "name") or ""
            payloads.append(("upstream.pom", data, result["pom_source_url"]))
            if not result["declared_licenses"] and xml.find(ns + "parent") is not None:
                parent = [xml.findtext(ns + "parent/" + ns + name) or "" for name in ("groupId", "artifactId", "version")]
                coordinate(":".join(parent))
                parents = sorted(cache.joinpath(*parent).glob("*/" + parent[1] + "-" + parent[2] + ".pom"))
                parent_values = {sha(p.read_bytes()): p.read_bytes() for p in parents}
                if len(parent_values) > 1:
                    raise ValueError("Conflicting parent POM metadata")
                if parent_values:
                    parent_digest, parent_bytes = next(iter(parent_values.items()))
                    parent_xml = ET.fromstring(parent_bytes)
                    parent_coordinate = [parent_xml.findtext(ns + field) or parent_xml.findtext(ns + "parent/" + ns + field) or ""
                                         for field in ("groupId", "artifactId", "version")]
                    if parent_coordinate != parent:
                        raise ValueError("Parent POM coordinate mismatch")
                    declared = [{"name": n.findtext(ns + "name") or "", "url": n.findtext(ns + "url") or ""}
                                for n in parent_xml.findall(ns + "licenses/" + ns + "license")]
                    parent_url = artifact_base(parent) + parent[1] + "-" + parent[2] + ".pom"
                    result["parent_pom"] = {"coordinate": ":".join(parent), "sha256": parent_digest,
                                             "source_url": parent_url, "declared_licenses": declared}
                    payloads.append(("upstream-parent.pom", parent_bytes, parent_url))
        else:
            model = json.loads(data)
            parent = [model["component"][name] for name in ("group", "module", "version")]
            redirected = parts[1] in (parent[1] + "-android", parent[1] + "-jvm") and model["component"].get("url")
            if parent != parts and not (parent[0] == parts[0] and parent[2] == parts[2] and redirected):
                raise ValueError("Module coordinate does not match selected artifact: " + ":".join(parts))
            result["module_component"] = model["component"]
            urls = {row["url"] for variant in model.get("variants", []) for row in variant.get("files", [])
                    if row.get("name") == artifact["file"] and row.get("sha256") == artifact["sha256"]}
            if len(urls) > 1:
                raise ValueError("Ambiguous upstream module artifact URL")
            if urls:
                result["artifact_source_url"] = https(urljoin(base, next(iter(urls))))
                result["artifact_url_basis"] = "original module metadata name/hash match"
    return result, payloads


def pinned_supplements(row, meta, cache, embedded, native):
    """Retain exact source texts; a POM-bound license is not native clearance."""
    result = []

    def original(name, role, reference):
        url, expected = PINNED_UPSTREAM_TEXTS[name]
        data = (cache / name).read_bytes()
        if sha(data) != expected:
            raise ValueError("Pinned upstream source text checksum mismatch: " + name)
        return {"name": name, "role": role, "_checked_bytes": data, "sha256": expected,
                "source_url": url, "upstream_reference": reference}

    if not embedded:
        parent = meta if meta.get("declared_licenses") else meta.get("parent_pom", {})
        declared = parent.get("declared_licenses", [])
        if len(declared) != 1 or declared[0]["url"].replace("http://", "https://", 1) != "https://www.apache.org/licenses/LICENSE-2.0.txt":
            raise ValueError("No pinned notice recipe for this publisher's declared license: " + row["coordinate"])
        notice = original("Apache-LICENSE-2.0.txt", "license", row["coordinate"] + " original publisher POM license declaration")
        notice["pom_basis"] = {"sha256": parent.get("pom_sha256", parent.get("sha256")),
                               "declared_license_url": declared[0]["url"]}
        result.append(notice)
    group, module, version = coordinate(row["coordinate"])
    if group == "org.jetbrains.kotlin":
        if module == "kotlin-stdlib" and version == "2.1.20":
            for name in ("Kotlin-2.1.20-LICENSE.txt", "Kotlin-2.1.20-license-README.md", "Kotlin-2.1.20-gwt_license.txt",
                         "Kotlin-2.1.20-threetenbp_license.txt", "Kotlin-2.1.20-guava_license.txt", "Kotlin-2.1.20-boost_LICENSE.txt"):
                result.append(original(name, "attribution" if name.endswith(".md") else "license", "Kotlin v2.1.20 stdlib source license summary"))
        elif module in ("kotlin-stdlib-jdk7", "kotlin-stdlib-jdk8") and version == "1.8.20":
            result.append(original("Kotlin-1.8.20-LICENSE.txt", "license", "Kotlin v1.8.20"))
        else:
            raise ValueError("Kotlin runtime version needs an explicit reviewed source-notice recipe")
    if group == "org.jetbrains.kotlinx":
        if module not in ("kotlinx-coroutines-android", "kotlinx-coroutines-core-jvm") or version != "1.7.3":
            raise ValueError("Coroutine runtime version needs an explicit reviewed source-notice recipe")
        result.append(original("Coroutines-1.7.3-LICENSE.txt", "license", "kotlinx.coroutines 1.7.3"))
    if group == "org.jetbrains" and module == "annotations":
        if version != "23.0.0":
            raise ValueError("Annotations version needs an explicit reviewed source-notice recipe")
        result.append(original("Annotations-23.0.0-LICENSE.txt", "license", "java-annotations 23.0.0"))
    # The ui AAR also carries an inspector.jar tooling sidecar. Its native files
    # are archive provenance, not evidence that they enter the main APK. The
    # inspected frozen main APKs contain neither that JAR nor its JNI library.
    tooling = [r for r in native if r["archive_entry"].startswith("inspector.jar!/lib/")]
    if tooling and row["coordinate"] != "androidx.compose.ui:ui-android:1.7.8":
        raise ValueError("Unknown nested frontend tooling native input needs scope review")
    runtime_native = [r for r in native if r not in tooling]
    if runtime_native:
        if row["coordinate"] != "androidx.graphics:graphics-path:1.0.1":
            raise ValueError("Selected native frontend input needs an explicit source attribution recipe: " + row["coordinate"])
        for name in sorted(PINNED_UPSTREAM_TEXTS):
            if not name.startswith("GraphicsPath-1.0.1-"):
                continue
            notice = original(name, "attribution", "graphics-path 1.0.1 official release-history endpoint 8a05a22af450d589ef911d772a001a49dcb05b71")
            data = notice["_checked_bytes"]
            if not data.startswith(b"/*") or data.find(b"*/") < 0:
                raise ValueError("Pinned native source lacks the expected original notice header")
            size = data.find(b"*/") + 2
            notice["name"] += ".notice.txt"
            notice["_checked_bytes"] = data[:size]
            notice["sha256"] = sha(data[:size])
            notice["source_file_path"] = str(cache / name)
            notice["source_file_sha256"] = sha(data)
            notice["source_byte_range"] = [0, size]
            result.append(notice)
    return result


def package(inventory, destination, cache, source_reference, source_revision, supplements=None, allow_missing=False, upstream_cache=None):
    https(source_reference)
    if not re.fullmatch(r"[0-9a-f]{40}", source_revision):
        raise ValueError("Source revision must be a full lowercase Git SHA1")
    document = json.loads(inventory.read_text())
    if document.get("schema") != 1 or document.get("configuration") not in ("debugRuntimeClasspath", "releaseRuntimeClasspath"):
        raise ValueError("Expected selected main APK runtime inventory schema 1")
    if not isinstance(document.get("artifacts"), list) or not document["artifacts"]:
        raise ValueError("Selected runtime artifact list must be nonempty")
    rows, occurrences = {}, Counter()
    for row in document["artifacts"]:
        coordinate(row["coordinate"])
        if not HASH.fullmatch(row["sha256"]) or not SAFE_PART.fullmatch(row["file"]) or row["file"] in (".", ".."):
            raise ValueError("Invalid selected artifact filename/hash")
        key = (row["coordinate"], row["file"], row["sha256"])
        if key in rows and Path(row["artifact_path"]).read_bytes() != Path(rows[key]["artifact_path"]).read_bytes():
            raise ValueError("Conflicting duplicate selected artifact")
        rows[key] = row
        occurrences[key] += 1
    supplemental = {}
    if supplements:
        supplied = json.loads(supplements.read_text())
        if supplied.get("schema") != 1:
            raise ValueError("Expected supplemental notice schema 1")
        for entry in supplied["components"]:
            key = (entry["coordinate"], entry["artifact_sha256"])
            if key in supplemental or not any(k[0] == key[0] and k[2] == key[1] for k in rows):
                raise ValueError("Duplicate or unselected supplemental component")
            supplemental[key] = entry
    outputs, components, missing = {}, [], []
    for key, row in sorted(rows.items()):
        parts = coordinate(row["coordinate"])
        data = Path(row["artifact_path"]).read_bytes()
        if sha(data) != row["sha256"]:
            raise ValueError("Selected artifact checksum mismatch: " + row["coordinate"])
        notices, native = archive_notices(data)
        component = {"coordinate": row["coordinate"], "version": parts[2], "artifact_file": row["file"],
                     "artifact_sha256": row["sha256"], "selection_occurrences": occurrences[key],
                     "embedded_notice_count": len(notices), "archive_native_entries": native, "notices": []}
        if any("!/" in item["archive_entry"] for item in native):
            component["nested_native_scope"] = "original nested JAR provenance; main APK presence is not asserted"
        meta, poms = metadata(cache, parts, row)
        component.update(meta)
        entries = [(name, value, {"origin": "original artifact member", "archive_entry": name,
                                 "source_url": meta["artifact_source_url"]}) for name, value in notices]
        entries += [(name, value, {"origin": "original publisher POM metadata", "source_url": url}) for name, value, url in poms]
        supplement = supplemental.get((row["coordinate"], row["sha256"]), {})
        supplied_notices = list(supplement.get("notices", []))
        if upstream_cache:
            # An exact-version supplemental license may cover a publisher outside the pinned Apache recipe.
            # The original bytes, hash and provenance are still checked below before anything is emitted.
            has_license = bool(notices) or any(item.get("role") == "license" for item in supplied_notices)
            supplied_notices.extend(pinned_supplements(row, meta, upstream_cache, has_license, native))
        for item in supplied_notices:
            if not SAFE_PART.fullmatch(item["name"]) or item["name"] in (".", "..") or item.get("role") not in ("license", "notice", "attribution"):
                raise ValueError("Invalid supplemental notice name/role")
            if not isinstance(item["upstream_reference"], str) or not item["upstream_reference"].strip():
                raise ValueError("Supplemental upstream version/reference is required")
            value = item.get("_checked_bytes")
            if value is not None and type(value) is not bytes:
                raise ValueError("Invalid internal notice bytes")
            if value is None:
                value = Path(item["notice_path"]).read_bytes()
            if len(value) > MAX_NOTICE or not HASH.fullmatch(item["sha256"]) or sha(value) != item["sha256"]:
                raise ValueError("Supplemental notice checksum/bound mismatch")
            origin = {"origin": "explicit upstream supplement", "source_url": https(item["source_url"]),
                      "upstream_reference": item["upstream_reference"], "role": item["role"]}
            if "pom_basis" in item:
                basis = item["pom_basis"]
                original_poms = [(meta.get("pom_sha256"), meta.get("declared_licenses", [])),
                                 (meta.get("parent_pom", {}).get("sha256"), meta.get("parent_pom", {}).get("declared_licenses", []))]
                if not any(digest == basis["sha256"] and basis["declared_license_url"] in [r["url"] for r in declared]
                           for digest, declared in original_poms):
                    raise ValueError("Supplemental license basis does not match original publisher POM")
                origin["pom_basis"] = basis
            if "source_byte_range" in item:
                original_source = Path(item["source_file_path"]).read_bytes()
                bounds = item["source_byte_range"]
                if (not HASH.fullmatch(item["source_file_sha256"]) or sha(original_source) != item["source_file_sha256"] or
                    len(bounds) != 2 or any(type(n) is not int for n in bounds) or
                    not 0 <= bounds[0] <= bounds[1] <= len(original_source) or original_source[bounds[0]:bounds[1]] != value):
                    raise ValueError("Supplemental source notice is not the checked original byte range")
                origin["source_file_sha256"] = item["source_file_sha256"]
                origin["source_byte_range"] = bounds
            entries.append((item["name"], value, origin))
        if not notices and not any(i["role"] == "license" for i in supplied_notices):
            missing.append(row["coordinate"])
        folder = "notices/" + "-".join(parts) + "-" + row["sha256"][:12]
        for number, (original, value, origin) in enumerate(entries):
            leaf = re.sub(r"[^A-Za-z0-9._-]", "_", original.rsplit("/", 1)[-1]) or "notice.txt"
            name = folder + "/" + str(number).zfill(3) + "-" + leaf
            if name in outputs:
                raise ValueError("Output notice path collision")
            outputs[name] = value
            component["notices"].append({"path": name, "sha256": sha(value), **origin})
        components.append(component)
    if missing and not allow_missing:
        raise ValueError("Missing primary license/notice bytes for selected inputs: " + ", ".join(missing))
    graph = [{"coordinate": k[0], "file": k[1], "sha256": k[2], "selection_occurrences": occurrences[k]} for k in sorted(rows)]
    manifest = {"schema": 1, "source_reference": source_reference, "source_revision": source_revision,
                "runtime_configuration": document["configuration"], "selected_artifact_rows": sum(occurrences.values()),
                "selected_unique_artifacts": len(rows), "selected_graph_sha256": sha(encoded(graph)), "components": components,
                "missing_primary_notice_components": missing, "notice_byte_coverage": "INCOMPLETE" if missing else "ALL_SELECTED_INPUTS_REPRESENTED",
                "scope": "selected main APK inputs and checked notice bytes; not distribution or complete source/relink clearance",
                "files": [{"path": name, "sha256": sha(outputs[name])} for name in sorted(outputs)]}
    outputs["manifest.json"] = encoded(manifest)
    destination = destination.absolute()
    if destination.is_symlink():
        raise ValueError("Notice destination is a symlink")
    if destination.exists():
        actual = {}
        for path in destination.rglob("*"):
            if path.is_symlink():
                raise ValueError("Symlink in notice destination")
            if path.is_file():
                actual[path.relative_to(destination).as_posix()] = path.read_bytes()
        if actual != outputs:
            raise ValueError("Existing notice destination differs; select fresh generated assets")
    else:
        destination.parent.mkdir(parents=True, exist_ok=True)
        stage = Path(tempfile.mkdtemp(prefix=".frontend-notices-", dir=destination.parent))
        try:
            for name, value in sorted(outputs.items()):
                path = stage / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(value)
                path.chmod(0o644)
            for path in stage.rglob("*"):
                if path.is_dir():
                    path.chmod(0o755)
            stage.chmod(0o755)
            os.rename(stage, destination)
        finally:
            if stage.exists():
                shutil.rmtree(stage)
    return {"schema": 1, "manifest_sha256": sha(outputs["manifest.json"]), "selected_unique_artifacts": len(rows),
            "files": len(outputs), "notice_byte_coverage": manifest["notice_byte_coverage"], "status": "OK"}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("inventory", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--metadata-cache", type=Path, required=True)
    parser.add_argument("--source-reference", required=True)
    parser.add_argument("--source-revision", required=True)
    parser.add_argument("--supplements", type=Path)
    parser.add_argument("--upstream-cache", type=Path, help="offline cache of pinned primary source texts listed in PINNED_UPSTREAM_TEXTS")
    parser.add_argument("--allow-missing", action="store_true", help="audit partial extraction; report missing original notice material explicitly")
    args = parser.parse_args()
    try:
        result = package(args.inventory, args.destination, args.metadata_cache, args.source_reference, args.source_revision,
                         args.supplements, args.allow_missing, args.upstream_cache)
    except (ValueError, OSError, KeyError, zipfile.BadZipFile, ET.ParseError) as error:
        parser.exit(2, "frontend notices: " + str(error) + "\n")
    print(json.dumps(result, sort_keys=True))
