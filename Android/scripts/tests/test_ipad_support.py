import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[3]


class IPadSupportTests(unittest.TestCase):
    def test_display_scan_present_capture_and_touch_roundtrip(self) -> None:
        harness = r'''
#include "display_scan.h"
#include <cassert>
#include <cmath>
#include <cstdint>
#include <vector>

// Exact lt_map_contact formula from Portable/src/Runtime.cpp and ipad1_map_touch from hw/arm/ipad1.c.
static void map_contact_90(double px, double py, const display_scan::Viewport &v, double &gx, double &gy) {
    const double nx = (px - v.left) / v.width;
    const double ny = (py - v.top) / v.height;
    gx = ny;
    gy = 1.0 - nx;
}

static void ipad1_map_touch(double panel_x_norm, double panel_y_norm, double &digitizer_x, double &digitizer_y_from_bottom) {
    digitizer_x = 1.0 - panel_y_norm;
    digitizer_y_from_bottom = 1.0 - panel_x_norm;
}

int main() {
    // 1. Portrait frames stay untouched.
    assert(!display_scan::is_landscape_scan(320, 480));
    assert(!display_scan::is_landscape_scan(640, 960));
    assert(display_scan::upright_width(320, 480) == 320);
    assert(display_scan::upright_height(320, 480) == 480);
    assert(display_scan::scan_rotation(320, 480) == 0);

    // 2. K48 iPad 1024x768 landscape scan turns upright to 768x1024 (+90 CW).
    constexpr uint32_t W = 1024, H = 768;
    assert(display_scan::is_landscape_scan(W, H));
    assert(display_scan::upright_width(W, H) == 768);
    assert(display_scan::upright_height(W, H) == 1024);
    assert(display_scan::scan_rotation(W, H) == 90);

    // Fits DeviceSkin.ipad's 3:4 cutout without letterboxing.
    const auto cut = display_scan::viewport(900, 1200, W, H);
    assert(std::abs(cut.left) < 1e-9 && std::abs(cut.top) < 1e-9);
    assert(std::abs(cut.width - 900.0) < 1e-9 && std::abs(cut.height - 1200.0) < 1e-9);

    // Encode each source pixel (sx, sy) into unique RGB: R = sx & 0xff, G = sy & 0xff, B = ((sx >> 8) << 4) | (sy >> 8).
    std::vector<uint8_t> src(size_t(W) * H * 4);
    for (uint32_t sy = 0; sy < H; ++sy) {
        for (uint32_t sx = 0; sx < W; ++sx) {
            uint8_t *p = src.data() + (size_t(sy) * W + sx) * 4;
            p[0] = uint8_t(((sx >> 8) << 4) | (sy >> 8));  // B
            p[1] = uint8_t(sy & 0xff);                     // G
            p[2] = uint8_t(sx & 0xff);                     // R
            p[3] = 0x12;                                   // ignored X channel
        }
    }

    auto expected_rgba = [](uint32_t ux, uint32_t uy) -> uint32_t {
        const uint32_t sx = uy;
        const uint32_t sy = (H - 1u) - ux;
        const uint32_t r = sx & 0xffu;
        const uint32_t g = sy & 0xffu;
        const uint32_t b = ((sx >> 8) << 4) | (sy >> 8);
        return r | (g << 8) | (b << 16) | 0xff000000u;
    };

    // 3. Test 1:1 ScaleGuest fast tiled path (768x1024 buffer with padded stride 800).
    constexpr int stride1 = 800;
    std::vector<uint32_t> dst1(size_t(stride1) * 1024, 0);
    const auto view1 = display_scan::viewport(768, 1024, W, H);
    display_scan::present_landscape_scan(dst1.data(), stride1, 768, 1024, view1, src.data(), W, H, W * 4);
    for (uint32_t uy = 0; uy < 1024; ++uy) {
        for (uint32_t ux = 0; ux < 768; ++ux) {
            assert(dst1[size_t(uy) * stride1 + ux] == expected_rgba(ux, uy));
        }
    }

    // 4. Test letterboxed ScaleCpu path on 1080x2400 phone screen (view = 1080x1440 centered at y = 480).
    constexpr int surf_w = 1080, surf_h = 2400;
    std::vector<uint32_t> dst_scaled(size_t(surf_w) * surf_h, 0);
    const auto view_scaled = display_scan::viewport(surf_w, surf_h, W, H);
    assert(std::abs(view_scaled.left - 0.0) < 1e-9);
    assert(std::abs(view_scaled.top - 480.0) < 1e-9);
    assert(std::abs(view_scaled.width - 1080.0) < 1e-9);
    assert(std::abs(view_scaled.height - 1440.0) < 1e-9);
    display_scan::present_landscape_scan(dst_scaled.data(), surf_w, surf_w, surf_h, view_scaled, src.data(), W, H, W * 4);
    // Top and bottom letterbox bars are opaque black.
    assert(dst_scaled[0] == 0xff000000u);
    assert(dst_scaled[size_t(479) * surf_w + 540] == 0xff000000u);
    assert(dst_scaled[size_t(1920) * surf_w + 540] == 0xff000000u);
    // Sample interior scaled pixels and verify touch round-trip to QEMU digitizer coordinates.
    for (double u : {0.05, 0.25, 0.5, 0.85}) {
        for (double v : {0.1, 0.4, 0.75, 0.95}) {
            const double px = view_scaled.left + u * view_scaled.width;
            const double py = view_scaled.top + v * view_scaled.height;
            const uint32_t ux = uint32_t(u * H);
            const uint32_t uy = uint32_t(v * W);
            assert(dst_scaled[size_t(int(py)) * surf_w + size_t(int(px))] == expected_rgba(ux, uy));

            double gx = 0, gy = 0, dig_x = 0, dig_y_bottom = 0;
            map_contact_90(px, py, view_scaled, gx, gy);
            ipad1_map_touch(gx, gy, dig_x, dig_y_bottom);
            assert(std::abs(dig_x - u) < 1e-9);
            assert(std::abs((1.0 - dig_y_bottom) - v) < 1e-9);
        }
    }

    // 5. Test capture_upright_rgba (768x1024 RGBA output).
    std::vector<uint8_t> cap(768u * 1024u * 4u, 0);
    display_scan::capture_upright_rgba(cap.data(), 768u * 4u, src.data(), W, H, W * 4);
    for (uint32_t uy : {0u, 17u, 511u, 1023u}) {
        for (uint32_t ux : {0u, 23u, 384u, 767u}) {
            const uint8_t *p = cap.data() + (size_t(uy) * 768u + ux) * 4u;
            const uint32_t got = uint32_t(p[0]) | (uint32_t(p[1]) << 8) | (uint32_t(p[2]) << 16) | (uint32_t(p[3]) << 24);
            assert(got == expected_rgba(ux, uy));
        }
    }
    return 0;
}
'''
        with tempfile.TemporaryDirectory() as tmp:
            src_path = Path(tmp) / "test.cpp"
            bin_path = Path(tmp) / "test"
            src_path.write_text(harness)
            subprocess.run(
                [
                    "g++", "-std=c++17", "-O2", "-Wall", "-Wextra", "-Werror",
                    f"-I{REPO / 'Android/app/src/main/cpp'}",
                    str(src_path), "-o", str(bin_path),
                ],
                check=True,
            )
            subprocess.run([str(bin_path)], check=True)

    def test_iboot32patcher_patch_arm32_bitfields_under_gcc_and_ms_bitfields(self) -> None:
        patch_text = (REPO / "build-support/patches/iBoot32Patcher-ltm.patch").read_text()
        self.assertIn("+++ b/include/arm32_defs.h", patch_text)
        # Reconstruct the patched struct definitions from the patch's + lines and verify sizes & MOVW decoding
        # under both standard SysV ABI and -mms-bitfields (MinGW/GCC bitfield packing ABI).
        added = []
        in_arm32 = False
        for line in patch_text.splitlines():
            if line.startswith("+++ b/include/arm32_defs.h"):
                in_arm32 = True
                continue
            if in_arm32 and line.startswith("--- "):
                break
            if in_arm32 and not line.startswith("@@"):
                if line.startswith(("+", " ")):
                    text_line = line[1:]
                    if not text_line.strip().startswith("#endif"):
                        added.append(text_line)
        probe = (
            "#include <cassert>\n#include <cstdint>\n#include <cstring>\n"
            + "\n".join(added)
            + """
int main() {
    static_assert(sizeof(arm32_thumb_LDR_T3) == 4, "LDR_T3");
    static_assert(sizeof(arm32_thumb_MOVW) == 4, "MOVW");
    static_assert(sizeof(arm32_thumb_BL) == 4, "BL");
    static_assert(sizeof(arm32_thumb_MOVT_W) == 4, "MOVT_W");
    static_assert(sizeof(arm32_thumb_BW_T4) == 4, "BW_T4");
    static_assert(sizeof(arm32_thumb_MOVT) == 4, "MOVT");
    static_assert(sizeof(arm32_thumb_IT_T1) == 2, "IT_T1");
    static_assert(sizeof(arm32_thumb_LDR) == 2, "LDR");
    static_assert(sizeof(arm32_thumb_hi_reg_op) == 2, "hi_reg_op");
    static_assert(sizeof(arm32_thumb) == 2, "thumb");

    // MOVW R1, #0x5441 ('TA'): halfwords 0xF245 0x4141 -> bytes 45 F2 41 41.
    const uint8_t movw_bytes[4] = {0x45, 0xF2, 0x41, 0x41};
    arm32_thumb_MOVW insn{};
    std::memcpy(&insn, movw_bytes, 4);
    assert(insn.pad0 == 0x24 && insn.pad1 == 0x1E && insn.bit31 == 0);
    assert(insn.rd == 1 && insn.imm4 == 5 && insn.i == 0 && insn.imm3 == 4 && insn.imm8 == 0x41);
    return 0;
}
"""
        )
        with tempfile.TemporaryDirectory() as tmp:
            src_path = Path(tmp) / "probe.cpp"
            bin_path = Path(tmp) / "probe"
            src_path.write_text(probe)
            for extra in ([], ["-mms-bitfields"]):
                subprocess.run(["g++", "-std=c++17", "-Wall", "-Wextra", "-Werror", *extra, str(src_path), "-o", str(bin_path)], check=True)
                subprocess.run([str(bin_path)], check=True)

    def test_stage_notices_includes_iboot32patcher_license(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            checkouts = root / "checkouts"
            linked = {
                "ZIPFoundation": ["LICENSE"],
                "swift-subprocess": ["LICENSE"],
                "Unrar.swift": ["LICENSE.txt", "Sources/Cunrar/license.txt"],
                "swift-argument-parser": ["LICENSE.txt"],
                "swift-crypto": ["LICENSE.txt", "NOTICE.txt"],
                "swift-asn1": ["LICENSE.txt", "NOTICE.txt"],
                "swift-system": ["LICENSE.txt"],
            }
            for slug, rels in linked.items():
                for rel in rels:
                    dest = checkouts / slug / rel
                    dest.parent.mkdir(parents=True, exist_ok=True)
                    dest.write_text(f"License for {slug} ({rel})\n")
            swift_lic = root / "swift-LICENSE.txt"
            swift_lic.write_text("Apache 2.0 Swift Runtime\n")
            iboot_lic = root / "iBoot32Patcher-LICENSE"
            iboot_lic.write_text("GNU GENERAL PUBLIC LICENSE Version 3\n")
            out = root / "licenses"
            subprocess.run(
                [
                    sys.executable,
                    str(REPO / "Packages/FirmwareKit/build-support/stage-notices.py"),
                    str(out),
                    "--checkouts", str(checkouts),
                    "--swift-license", str(swift_lic),
                    "--iboot32patcher-license", str(iboot_lic),
                    "--source-reference", "https://github.com/rubiidev18alt/Un1box/tree/main",
                ],
                check=True,
            )
            manifest = json.loads((out / "manifest.json").read_text())
            by_file = {entry["path"]: entry["sha256"] for entry in manifest["files"]}
            self.assertIn("iBoot32Patcher-LICENSE", by_file)
            self.assertEqual(by_file["iBoot32Patcher-LICENSE"], hashlib.sha256(iboot_lic.read_bytes()).hexdigest())
            self.assertIn("iBoot32Patcher", (out / "NOTICE.txt").read_text())

    def test_catalog_firmwarekit_and_android_ipad_wiring(self) -> None:
        catalog = json.loads((REPO / "Portable/firmware/firmware-catalog.json").read_text())
        ids = {e["id"] for e in catalog["entries"]}
        k48 = [e for e in catalog["entries"] if e.get("board") == "k48ap"]
        self.assertGreaterEqual(len(k48), 20)
        sibling_k48 = [e for e in k48 if (e.get("recipe") or {}).get("keybag_ramdisk_from")]
        self.assertEqual({e["id"] for e in sibling_k48}, {"k48ap-8G4", "k48ap-8H7", "k48ap-8J3", "k48ap-8K2", "k48ap-8L1"})
        for entry in sibling_k48:
            self.assertIn(entry["recipe"]["keybag_ramdisk_from"], ids)

        k48_iboot = (REPO / "Packages/FirmwareKit/Sources/FirmwareKit/K48IBoot/K48IBoot.swift").read_text()
        self.assertNotIn('"/usr/bin/env"', k48_iboot)
        self.assertIn('"libiboot32patcher.so"', k48_iboot)
        self.assertIn("p.executableURL = tool", k48_iboot)

        stopped_jb = (REPO / "Packages/FirmwareKit/Sources/FirmwareKit/StoppedVolumeEdit/StoppedVolumeEdit+Jailbreak.swift").read_text()
        self.assertIn("SandboxPatch.rewrapKernelcache", stopped_jb)

        cli_main = (REPO / "Packages/FirmwareKit/Sources/FirmwareKitCLI/main.swift").read_text()
        self.assertIn("keybagRamdiskFrom", cli_main)

        gradle = (REPO / "Android/app/build.gradle.kts").read_text()
        self.assertIn("libiboot32patcher.so", gradle)

        workflow = (REPO / ".github/workflows/android-perf-apk.yml").read_text()
        self.assertIn("build-iboot32patcher.py", workflow)
        self.assertIn("--iboot32patcher-license", workflow)

        aidl = (REPO / "Android/app/src/main/aidl/org/un1box/android/IFirmware.aidl").read_text()
        self.assertIn("Bundle start(String firmwareId, String ipswPath, String trustedToolsRoot, String bootromPath, boolean jailbreak);", aidl)
        self.assertIn("Bundle startWithSibling(", aidl)

        fw_service = (REPO / "Android/app/src/main/java/org/un1box/android/FirmwareService.kt").read_text()
        self.assertIn("FIRMWAREKIT_IBOOT_PATCHER", fw_service)
        self.assertIn('"--sibling-ipsw"', fw_service)


if __name__ == "__main__":
    unittest.main()
