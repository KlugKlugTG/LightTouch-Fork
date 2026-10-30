#pragma once
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Landscape-scan upright presentation and capture helpers.
//
// K48 (iPad 1st gen, 1024x768 Pinot panel) scans its portrait UI rotated 90 degrees
// counterclockwise into a 1024x768 BGRA framebuffer (ipad1.c: touch_landscape = true,
// digitizer x = 1 - panel_y, digitizer y_from_top = panel_x). Portrait panels (320x480,
// 640x960) have width <= height and scan upright directly.

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <vector>

namespace display_scan {

struct Viewport {
    double left;
    double top;
    double width;
    double height;
};

inline constexpr bool is_landscape_scan(uint32_t frame_width, uint32_t frame_height) {
    return frame_width > frame_height;
}

inline constexpr uint32_t upright_width(uint32_t frame_width, uint32_t frame_height) {
    return is_landscape_scan(frame_width, frame_height) ? frame_height : frame_width;
}

inline constexpr uint32_t upright_height(uint32_t frame_width, uint32_t frame_height) {
    return is_landscape_scan(frame_width, frame_height) ? frame_width : frame_height;
}

inline constexpr uint32_t scan_rotation(uint32_t frame_width, uint32_t frame_height) {
    return is_landscape_scan(frame_width, frame_height) ? 90u : 0u;
}

inline uint32_t bgra_to_rgba(const uint8_t *p) {
    return uint32_t(p[2]) | (uint32_t(p[1]) << 8) | (uint32_t(p[0]) << 16) | 0xff000000u;
}

inline Viewport viewport(int surface_width, int surface_height, uint32_t frame_width, uint32_t frame_height, bool fill = false) {
    const uint32_t uw = upright_width(frame_width, frame_height);
    const uint32_t uh = upright_height(frame_width, frame_height);
    if (!uw || !uh || surface_width <= 0 || surface_height <= 0) return {0, 0, 0, 0};
    const double sx = double(surface_width) / double(uw);
    const double sy = double(surface_height) / double(uh);
    const double scale = fill ? std::max(sx, sy) : std::min(sx, sy);
    const double w = uw * scale;
    const double h = uh * scale;
    return {(surface_width - w) / 2.0, (surface_height - h) / 2.0, w, h};
}

// Presents a landscape-scanned BGRA guest frame (frame_width > frame_height, e.g. 1024x768)
// upright (+90 degrees clockwise, upright size frame_height x frame_width = 768x1024)
// into an RGBA_8888 destination window buffer, filling any letterbox/pillarbox margins with opaque black.
inline void present_landscape_scan(
    uint32_t *dst,
    int dst_stride,
    int target_width,
    int target_height,
    const Viewport &view,
    const uint8_t *src,
    uint32_t frame_width,
    uint32_t frame_height,
    uint32_t src_stride
) {
    if (!dst || !src || target_width <= 0 || target_height <= 0 || !frame_width || !frame_height) return;

    // Fast 1:1 path (default ScaleGuest buffer: target == frame_height x frame_width == 768x1024).
    if (int(frame_height) == target_width && int(frame_width) == target_height) {
        constexpr int kTile = 16;
        for (int dy0 = 0; dy0 < target_height; dy0 += kTile) {
            const int dy_end = std::min(dy0 + kTile, target_height);
            for (int dx0 = 0; dx0 < target_width; dx0 += kTile) {
                const int dx_end = std::min(dx0 + kTile, target_width);
                for (int dx = dx0; dx < dx_end; ++dx) {
                    const uint8_t *src_row = src + size_t(int(frame_height) - 1 - dx) * src_stride;
                    for (int dy = dy0; dy < dy_end; ++dy) {
                        dst[size_t(dy) * size_t(dst_stride) + size_t(dx)] = bgra_to_rgba(src_row + size_t(dy) * 4u);
                    }
                }
            }
        }
        return;
    }

    if (view.width <= 0.0 || view.height <= 0.0) {
        for (int y = 0; y < target_height; ++y) {
            uint32_t *row = dst + size_t(y) * size_t(dst_stride);
            std::fill(row, row + target_width, 0xff000000u);
        }
        return;
    }

    const int x0 = std::max(int(view.left), 0);
    int x1 = x0;
    while (x1 < view.left + view.width && x1 < target_width) ++x1;

    static thread_local std::vector<uint32_t> src_rows;
    src_rows.resize(size_t(std::max(x1 - x0, 0)));
    for (int x = x0; x < x1; ++x) {
        const uint32_t ux = std::min(uint32_t((x - view.left) * frame_height / view.width), frame_height - 1u);
        src_rows[size_t(x - x0)] = (frame_height - 1u) - ux;
    }

    const uint32_t *previous = nullptr;
    uint32_t previous_sx = UINT32_MAX;
    for (int y = 0; y < target_height; ++y) {
        uint32_t *row = dst + size_t(y) * size_t(dst_stride);
        if (y < view.top || y >= view.top + view.height) {
            std::fill(row, row + target_width, 0xff000000u);
            continue;
        }
        const uint32_t sx = std::min(uint32_t((y - view.top) * frame_width / view.height), frame_width - 1u);
        if (previous && sx == previous_sx) {
            std::memcpy(row, previous, size_t(target_width) * sizeof(uint32_t));
            continue;
        }
        std::fill(row, row + x0, 0xff000000u);
        std::fill(row + x1, row + target_width, 0xff000000u);
        const size_t col_off = size_t(sx) * 4u;
        for (int x = x0; x < x1; ++x) {
            row[x] = bgra_to_rgba(src + size_t(src_rows[size_t(x - x0)]) * src_stride + col_off);
        }
        previous = row;
        previous_sx = sx;
    }
}

// Writes an upright RGBA_8888 screenshot of size upright_width x upright_height.
inline void capture_upright_rgba(
    uint8_t *dst,
    uint32_t dst_stride_bytes,
    const uint8_t *src,
    uint32_t frame_width,
    uint32_t frame_height,
    uint32_t src_stride_bytes
) {
    if (!dst || !src || !frame_width || !frame_height) return;
    if (!is_landscape_scan(frame_width, frame_height)) {
        for (uint32_t y = 0; y < frame_height; ++y) {
            const uint8_t *srow = src + size_t(y) * src_stride_bytes;
            uint8_t *drow = dst + size_t(y) * dst_stride_bytes;
            for (uint32_t x = 0; x < frame_width; ++x) {
                const uint8_t *sp = srow + size_t(x) * 4u;
                uint8_t *dp = drow + size_t(x) * 4u;
                dp[0] = sp[2];
                dp[1] = sp[1];
                dp[2] = sp[0];
                dp[3] = 255;
            }
        }
        return;
    }
    const uint32_t uw = frame_height;
    const uint32_t uh = frame_width;
    for (uint32_t dy = 0; dy < uh; ++dy) {
        uint8_t *drow = dst + size_t(dy) * dst_stride_bytes;
        const size_t src_col = size_t(dy) * 4u;
        for (uint32_t dx = 0; dx < uw; ++dx) {
            const uint8_t *sp = src + size_t(frame_height - 1u - dx) * src_stride_bytes + src_col;
            uint8_t *dp = drow + size_t(dx) * 4u;
            dp[0] = sp[2];
            dp[1] = sp[1];
            dp[2] = sp[0];
            dp[3] = 255;
        }
    }
}

}  // namespace display_scan
