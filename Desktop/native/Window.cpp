#include "include/Window.h"
#define SDL_MAIN_HANDLED
#include "../ui/ControlBar.hpp"
#include "../ui/Presentation.hpp"
#include "../ui/Cursor.hpp"
#include <deque>
#include <map>
#include <new>

struct LTDesktopWindow {
    SDL_Window *window = nullptr;
    SDL_Renderer *renderer = nullptr;
    SDL_Texture *texture = nullptr;
    int guest_width = 0, guest_height = 0;
    int display_rotation = 0;
    bool enabled = false, stopping = false, paused = false;
    lt::WindowControls controls;
    using Owner = lt::WindowControls::Owner;
    struct Contact { int slot; double x, y; };
    std::map<Owner, Contact> contacts;
    std::deque<LTDesktopEvent> pending;

    lt::ControlBarLayout layout() const {
        int width = 0, height = 0;
        SDL_GetWindowSize(window, &width, &height);
        return {width, height};
    }
    void emit(int kind, int identifier = 0, int phase = 0, double x = 0, double y = 0) {
        pending.push_back({kind, identifier, phase, x, y});
    }
    void edge(int button, bool down) { emit(LT_DESKTOP_BUTTON, button, down); }
    void cancel() {
        for (const auto &command : lt::desktop_commands)
            if (command.hardware_button >= 0 && controls.active(command.action))
                edge(command.hardware_button, false);
        controls.clear();
        for (const auto &item : contacts)
            emit(LT_DESKTOP_TOUCH, item.second.slot, 2, item.second.x, item.second.y);
        contacts.clear();
    }
    void activate(lt::WindowAction action) {
        using A = lt::WindowAction;
        if (action == A::pause || action == A::rotate || action == A::stop)
            cancel();
        if (action == A::pause) emit(LT_DESKTOP_PAUSE);
        if (action == A::rotate) {
            display_rotation = (display_rotation + 90) % 360;
            // Presentation is owned here. The semantic event lets a platform
            // additionally notify guest orientation without controlling video.
            emit(LT_DESKTOP_ROTATE);
        }
        if (action == A::screenshot) emit(LT_DESKTOP_SCREENSHOT);
        if (action == A::stop) {
            enabled = false;
            stopping = true;
            emit(LT_DESKTOP_STOP);
        }
    }
    int effective_rotation() const {
        return (display_rotation + (guest_width > guest_height ? 90 : 0)) % 360;
    }
    bool position(double px, double py, double &x, double &y) const {
        const int rot = effective_rotation();
        const auto view = layout().guest(guest_width, guest_height, rot);
        if (view.width <= 0 || view.height <= 0 || px < view.left || py < view.top ||
            px >= view.left + view.width || py >= view.top + view.height)
            return false;
        const double u = (px - view.left) / view.width, v = (py - view.top) / view.height;
        // Inverse of SDL's clockwise presentation, in native guest coordinates.
        switch (rot) {
        case 90: x = v; y = 1 - u; break;
        case 180: x = 1 - u; y = 1 - v; break;
        case 270: x = 1 - v; y = u; break;
        default: x = u; y = v; break;
        }
        return true;
    }
    void pointer(Owner owner, int phase, double px, double py) {
        const auto hit = layout().hit(px, py);
        auto edge = [&](int b, bool d) { this->edge(b, d); };
        if (controls.owns(owner)) {
            if (phase == 1 && !controls.matches(owner, hit)) controls.leave(owner, edge);
            if (phase == 2) controls.release(owner, hit, edge, [&](auto a) { activate(a); });
            return;
        }
        if (phase == 0 && hit != lt::WindowAction::none) {
            if (paused && lt::desktop_button(hit) >= 0) return;
            controls.press(owner, hit, edge);
            return;
        }
        if (paused) return;
        double x = 0, y = 0;
        const bool inside = position(px, py, x, y);
        auto found = contacts.find(owner);
        if (phase == 0) {
            if (!inside || found != contacts.end()) return;
            int slot = 0;
            for (; slot < 10; ++slot) {
                bool used = false;
                for (const auto &item : contacts) used |= item.second.slot == slot;
                if (!used) break;
            }
            if (slot == 10) return;
            contacts.emplace(owner, Contact{slot, x, y});
            emit(LT_DESKTOP_TOUCH, slot, 0, x, y);
        } else if (found != contacts.end()) {
            // Leaving the guest ends this contact. Re-entry needs a fresh down.
            auto contact = found->second;
            if (inside) { contact.x = x; contact.y = y; found->second = contact; }
            emit(LT_DESKTOP_TOUCH, contact.slot, !inside || phase == 2 ? 2 : 1, contact.x, contact.y);
            if (!inside || phase == 2) contacts.erase(found);
        }
    }
    void dispatch(const SDL_Event &event) {
        lt::desktop_cursor_event(window, event);
        if (event.type == SDL_QUIT || (event.type == SDL_WINDOWEVENT && event.window.event == SDL_WINDOWEVENT_CLOSE)) {
            if (!stopping) activate(lt::WindowAction::stop);
            return;
        }
        if (event.type == SDL_WINDOWEVENT) {
            if (event.window.event == SDL_WINDOWEVENT_FOCUS_LOST || event.window.event == SDL_WINDOWEVENT_SIZE_CHANGED)
                cancel();
            if (event.window.event == SDL_WINDOWEVENT_MINIMIZED || event.window.event == SDL_WINDOWEVENT_HIDDEN) {
                cancel(); emit(LT_DESKTOP_VISIBLE, 0, 0);
            }
            if (event.window.event == SDL_WINDOWEVENT_RESTORED || event.window.event == SDL_WINDOWEVENT_SHOWN)
                emit(LT_DESKTOP_VISIBLE, 0, 1);
        }
        if (!enabled) return;
        auto edge = [&](int b, bool d) { this->edge(b, d); };
        if (event.type == SDL_KEYDOWN || event.type == SDL_KEYUP) {
            if (event.key.repeat) return;
            const auto action = lt::desktop_shortcut(event.key.keysym.sym);
            const Owner owner{2, event.key.keysym.sym};
            if (action == lt::WindowAction::cancel) { if (event.type == SDL_KEYDOWN) cancel(); return; }
            if (paused && lt::desktop_button(action) >= 0 && event.type == SDL_KEYDOWN) return;
            if (event.type == SDL_KEYDOWN) controls.press(owner, action, edge);
            else controls.release(owner, action, edge, [&](auto a) { activate(a); });
        } else if (event.type == SDL_FINGERDOWN || event.type == SDL_FINGERMOTION || event.type == SDL_FINGERUP) {
            if (event.tfinger.touchId == SDL_MOUSE_TOUCHID) return;
            const auto bounds = layout();
            pointer({1, event.tfinger.fingerId}, event.type == SDL_FINGERDOWN ? 0 : event.type == SDL_FINGERUP ? 2 : 1,
                    event.tfinger.x * bounds.width, event.tfinger.y * bounds.window_height);
        } else if (event.type == SDL_MOUSEBUTTONDOWN || event.type == SDL_MOUSEBUTTONUP) {
            if (event.button.which == SDL_TOUCH_MOUSEID || event.button.button != SDL_BUTTON_LEFT) return;
            pointer({0, 0}, event.type == SDL_MOUSEBUTTONDOWN ? 0 : 2, event.button.x, event.button.y);
        } else if (event.type == SDL_MOUSEMOTION && event.motion.which != SDL_TOUCH_MOUSEID) {
            pointer({0, 0}, 1, event.motion.x, event.motion.y);
        }
    }
};

static bool active_window = false;
extern "C" LTDesktopWindow *lt_desktop_window_create(const char *title, int width, int height) {
    if (active_window || !title || width < 320 || height < 180) {
        SDL_SetError("One desktop guest window is supported; minimum size is 320x180");
        return nullptr;
    }
    SDL_SetMainReady(); // Swift owns main; no SDL_main trampoline.
    if (SDL_InitSubSystem(SDL_INIT_VIDEO | SDL_INIT_EVENTS) != 0) return nullptr;
    auto *result = new (std::nothrow) LTDesktopWindow;
    if (!result) { SDL_QuitSubSystem(SDL_INIT_VIDEO | SDL_INIT_EVENTS); SDL_SetError("Out of memory"); return nullptr; }
    active_window = true;
    result->window = SDL_CreateWindow(title, SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED, width, height,
                                     SDL_WINDOW_RESIZABLE | SDL_WINDOW_ALLOW_HIGHDPI);
    if (result->window)
        result->renderer = SDL_CreateRenderer(result->window, -1, SDL_RENDERER_ACCELERATED);
    SDL_RendererInfo info{};
    if (!result->renderer || SDL_GetRendererInfo(result->renderer, &info) != 0 ||
        !(info.flags & SDL_RENDERER_ACCELERATED) || (info.flags & SDL_RENDERER_SOFTWARE)) {
        lt_desktop_window_destroy(result);
        SDL_SetError("A hardware-accelerated SDL renderer is required");
        return nullptr;
    }
    SDL_SetWindowMinimumSize(result->window, 320, 180);
    lt::desktop_cursor(result->window);
    return result;
}
extern "C" const char *lt_desktop_window_error() { return SDL_GetError(); }
extern "C" void lt_desktop_window_destroy(LTDesktopWindow *window) {
    if (!window) return;
    SDL_DestroyTexture(window->texture);
    SDL_DestroyRenderer(window->renderer);
    SDL_DestroyWindow(window->window);
    delete window;
    active_window = false;
    SDL_QuitSubSystem(SDL_INIT_VIDEO | SDL_INIT_EVENTS);
}
extern "C" int lt_desktop_window_frame(LTDesktopWindow *window, const void *bgra, int width, int height, int pitch) {
    if (!window || !bgra || width <= 0 || height <= 0 || width > 8192 || height > 8192 || pitch < width * 4)
        return SDL_SetError("Invalid BGRA frame");
    if (width != window->guest_width || height != window->guest_height) {
        window->cancel();
        auto *texture = lt::opaque_texture(window->renderer, width, height);
        if (!texture) return -1;
        SDL_DestroyTexture(window->texture);
        window->texture = texture;
        window->guest_width = width; window->guest_height = height;
    }
    return SDL_UpdateTexture(window->texture, nullptr, bgra, pitch);
}
extern "C" int lt_desktop_window_present(LTDesktopWindow *window, int paused, int stopping) {
    if (!window) return SDL_SetError("Missing guest window");
    const auto layout = window->layout();
    if (SDL_RenderSetLogicalSize(window->renderer, layout.width, layout.window_height) != 0) return -1;
    SDL_SetRenderDrawColor(window->renderer, 12, 14, 18, 255);
    if (SDL_RenderClear(window->renderer) != 0) return -1;
    if (window->texture) {
        const int rot = window->effective_rotation();
        const auto view = layout.guest(window->guest_width, window->guest_height, rot);
        // SDL rotates about the destination centre, so this rectangle keeps the
        // unrotated dimensions while the viewport fits their rotated bounds.
        const double width = window->guest_width * view.scale, height = window->guest_height * view.scale;
        const SDL_FRect destination{float((layout.width - width) / 2), float((layout.top() - height) / 2),
                                   float(width), float(height)};
        if (SDL_RenderCopyExF(window->renderer, window->texture, nullptr, &destination,
                              rot, nullptr, SDL_FLIP_NONE) != 0) return -1;
    }
    lt::draw_control_bar(window->renderer, layout, window->controls, paused != 0, stopping != 0);
    SDL_RenderPresent(window->renderer);
    return 0;
}
extern "C" int lt_desktop_window_poll(LTDesktopWindow *window, LTDesktopEvent *event) {
    if (!window || !event) return -1;
    SDL_Event input;
    for (int count = 0; window->pending.empty() && count < 256 && SDL_PollEvent(&input); ++count)
        window->dispatch(input);
    if (window->pending.empty()) return 0;
    *event = window->pending.front(); window->pending.pop_front();
    return 1;
}
extern "C" void lt_desktop_window_cancel(LTDesktopWindow *window) { if (window) window->cancel(); }
extern "C" void lt_desktop_window_enabled(LTDesktopWindow *window, int enabled) {
    if (!window) return;
    if (!enabled) window->cancel();
    window->enabled = enabled != 0 && !window->stopping;
}
extern "C" void lt_desktop_window_paused(LTDesktopWindow *window, int paused) {
    if (!window) return;
    if (paused) window->cancel();
    window->paused = paused != 0;
}
