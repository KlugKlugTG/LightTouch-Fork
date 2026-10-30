// Asset-free adapter test. Dummy SDL video is used only to supply window
// geometry; production create must reject its unavailable hardware renderer.
#include "../native/Window.cpp"
#include <cassert>
#include <cmath>
#include <array>
#include <iostream>
#include <vector>

int main(int argc, char **argv) {
    assert(argc <= 2); // Optional private directory for synthetic render evidence.
    assert(SDL_setenv("SDL_VIDEODRIVER", "dummy", 1) == 0);
    assert(SDL_InitSubSystem(SDL_INIT_VIDEO | SDL_INIT_EVENTS) == 0);
    LTDesktopWindow window;
    window.window = SDL_CreateWindow("synthetic adapter geometry", 0, 0, 480, 800, SDL_WINDOW_HIDDEN);
    assert(window.window);
    window.guest_width = 320; window.guest_height = 480; window.enabled = true;
    auto take = [&] {
        std::vector<LTDesktopEvent> events(window.pending.begin(), window.pending.end());
        window.pending.clear(); return events;
    };
    auto key = [&](SDL_Keycode code, bool down) {
        SDL_Event event{};
        event.type = down ? SDL_KEYDOWN : SDL_KEYUP;
        event.key.keysym.sym = code;
        window.dispatch(event);
    };
    // A previous SDL client may have hidden the pointer. Absolute guest touch
    // never needs relative mouse mode or an invisible host cursor, including
    // while paused or stopping. Test the actual window event path.
    SDL_Event enter{}; enter.type = SDL_WINDOWEVENT;
    for (auto reason : {SDL_WINDOWEVENT_ENTER, SDL_WINDOWEVENT_FOCUS_GAINED}) {
        SDL_ShowCursor(SDL_DISABLE);
        assert(SDL_ShowCursor(SDL_QUERY) == SDL_DISABLE);
        enter.window.event = reason;
        window.dispatch(enter);
        assert(SDL_ShowCursor(SDL_QUERY) == SDL_ENABLE);
        assert(SDL_GetRelativeMouseMode() == SDL_FALSE);
        assert(SDL_GetCursor() == SDL_GetDefaultCursor());
        assert(take().empty()); // Visibility must not inject guest input.
    }
    const auto home = window.layout().rect(0);
    const double hx = home.x + home.w / 2, hy = home.y + home.h / 2;
    window.pointer({0, 0}, 0, hx, hy);
    key(SDLK_h, true);
    auto events = take();
    assert(events.size() == 1 && events[0].kind == LT_DESKTOP_BUTTON && events[0].phase == 1);
    window.pointer({0, 0}, 2, hx, hy);
    assert(take().empty()); // Keyboard still owns Home.
    key(SDLK_h, false);
    events = take();
    assert(events.size() == 1 && events[0].identifier == 0 && events[0].phase == 0);

    const auto view = window.layout().guest(320, 480, 0);
    const double left = view.left + .2 * view.width, right = view.left + .8 * view.width;
    const double y = view.top + .5 * view.height;
    window.pointer({1, 11}, 0, left, y);
    window.pointer({1, 22}, 0, right, y);
    events = take();
    assert(events.size() == 2 && events[0].identifier == 0 && events[1].identifier == 1);
    window.pointer({1, 11}, 1, right, y);
    window.pointer({1, 22}, 1, left, y);
    events = take();
    assert(events.size() == 2 && events[0].identifier == 0 && events[1].identifier == 1);
    assert(std::abs(events[0].x - .8) < 1e-8 && std::abs(events[1].x - .2) < 1e-8);
    window.pointer({1, 11}, 2, right, y);
    events = take();
    assert(events.size() == 1 && events[0].identifier == 0 && events[0].phase == 2);
    assert(window.contacts.size() == 1);
    key(SDLK_p, true);
    take();
    SDL_Event focus{}; focus.type = SDL_WINDOWEVENT; focus.window.event = SDL_WINDOWEVENT_FOCUS_LOST;
    window.dispatch(focus);
    events = take();
    assert(events.size() == 2 && events[0].kind == LT_DESKTOP_BUTTON && events[0].phase == 0);
    assert(events[1].kind == LT_DESKTOP_TOUCH && events[1].identifier == 1 && events[1].phase == 2);
    key(SDLK_p, false);
    window.pointer({1, 22}, 2, left, y);
    assert(take().empty());

    // Toolbar drag-off cannot turn into a guest contact or fire a command.
    window.pointer({0, 0}, 0, hx, hy);
    take();
    window.pointer({0, 0}, 1, left, y);
    events = take(); assert(events.size() == 1 && events[0].phase == 0);
    window.pointer({0, 0}, 2, left, y);
    assert(take().empty() && window.contacts.empty());

    for (int finger = 0; finger < 11; ++finger) window.pointer({1, finger}, 0, left, y);
    assert(window.contacts.size() == 10 && take().size() == 10);
    // Pause releases every contact before delivering the action.
    key(SDLK_SPACE, true); key(SDLK_SPACE, false);
    events = take(); assert(events.size() == 11);
    for (int i = 0; i < 10; ++i) assert(events[i].kind == LT_DESKTOP_TOUCH && events[i].phase == 2);
    assert(events.back().kind == LT_DESKTOP_PAUSE && window.contacts.empty());
    lt_desktop_window_paused(&window, 1);
    SDL_ShowCursor(SDL_DISABLE);
    window.dispatch(enter);
    assert(SDL_ShowCursor(SDL_QUERY) == SDL_ENABLE);
    window.pointer({1, 9}, 0, left, y);
    key(SDLK_h, true); key(SDLK_h, false);
    assert(take().empty() && window.contacts.empty());
    // Pause remains reachable while guest touch/hardware edges are suppressed.
    key(SDLK_SPACE, true); key(SDLK_SPACE, false);
    events = take(); assert(events.size() == 1 && events[0].kind == LT_DESKTOP_PAUSE);
    lt_desktop_window_paused(&window, 0);

    SDL_Event synthetic{}; synthetic.type = SDL_FINGERDOWN;
    synthetic.tfinger.touchId = SDL_MOUSE_TOUCHID; synthetic.tfinger.x = .5; synthetic.tfinger.y = .5;
    window.dispatch(synthetic);
    assert(take().empty());
    window.pointer({1, 100}, 0, left, y); take();
    window.pointer({1, 100}, 1, hx, hy);
    events = take();
    assert(events.size() == 1 && events[0].kind == LT_DESKTOP_TOUCH && events[0].phase == 2);
    window.pointer({1, 100}, 1, right, y);
    assert(take().empty()); // Contact cannot be re-created without a fresh down.

    // Exercise the actual Rotate button and production present/input functions.
    // A software target is injected only for deterministic host pixel readback;
    // production create below must continue rejecting software-only renderers.
    auto *surface = SDL_CreateRGBSurfaceWithFormat(0, 480, 800, 32, SDL_PIXELFORMAT_ARGB8888);
    assert(surface);
    window.renderer = SDL_CreateSoftwareRenderer(surface);
    assert(window.renderer);
    const std::array<uint8_t, 24> bgra{
        0,0,255,0, 0,255,0,0, 255,0,0,0, 0,255,255,0, 255,255,0,0, 255,0,255,0};
    assert(lt_desktop_window_frame(&window, bgra.data(), 2, 3, 8) == 0);
    assert(take().empty());
    const std::array<std::array<uint8_t,3>,6> colors{{
        {255,0,0}, {0,255,0}, {0,0,255}, {255,255,0}, {0,255,255}, {255,0,255}}};
    std::vector<uint8_t> pixels(480 * 800 * 4);
    auto verify_rotation = [&](int rotation, bool touches) {
        assert(window.display_rotation == rotation);
        assert(lt_desktop_window_present(&window, !touches, 0) == 0);
        assert(SDL_RenderReadPixels(window.renderer, nullptr, SDL_PIXELFORMAT_RGBA32, pixels.data(), 480 * 4) == 0);
        const auto rotated = window.layout().guest(2, 3, rotation);
        for (int i = 0; i < 6; ++i) {
            const double gx = (i % 2 + .5) / 2, gy = (i / 2 + .5) / 3;
            double u = gx, v = gy;
            if (rotation == 90) { u = 1 - gy; v = gx; }
            if (rotation == 180) { u = 1 - gx; v = 1 - gy; }
            if (rotation == 270) { u = gy; v = 1 - gx; }
            const double px = rotated.left + u * rotated.width, py = rotated.top + v * rotated.height;
            const auto *pixel = pixels.data() + (int(py) * 480 + int(px)) * 4;
            assert(pixel[0] == colors[i][0] && pixel[1] == colors[i][1] && pixel[2] == colors[i][2] && pixel[3] == 255);
            if (touches) {
                window.pointer({1, 700}, 0, px, py);
                window.pointer({1, 700}, 2, px, py);
                const auto contacts = take();
                assert(contacts.size() == 2 && contacts[0].phase == 0 && contacts[1].phase == 2);
                assert(std::abs(contacts[0].x - gx) < 1e-8 && std::abs(contacts[0].y - gy) < 1e-8);
            }
        }
        // Rotation never maps letterboxing/the fixed toolbar into guest input.
        window.pointer({1, 701}, 0, 0, 0);
        window.pointer({1, 701}, 2, 0, 0);
        assert(take().empty());
        if (argc == 2) {
            const std::string path = std::string(argv[1]) + "/rotation-" + std::to_string(rotation) + ".bmp";
            assert(SDL_SaveBMP(surface, path.c_str()) == 0);
        }
    };
    verify_rotation(0, true);
    // Cancel both guest contacts and a hardware hold BEFORE rotating coordinates.
    window.pointer({1, 800}, 0, left, y);
    window.pointer({1, 801}, 0, right, y);
    key(SDLK_h, true); take();
    const auto rotate = window.layout().rect(5);
    const double rx = rotate.x + rotate.w / 2, ry = rotate.y + rotate.h / 2;
    window.pointer({0, 0}, 0, rx, ry);
    window.pointer({0, 0}, 2, rx, ry);
    events = take();
    assert(events.size() == 4 && events[0].kind == LT_DESKTOP_BUTTON && events[0].phase == 0);
    assert(events[1].kind == LT_DESKTOP_TOUCH && events[1].phase == 2);
    assert(events[2].kind == LT_DESKTOP_TOUCH && events[2].phase == 2);
    assert(events.back().kind == LT_DESKTOP_ROTATE && window.contacts.empty());
    key(SDLK_h, false); assert(take().empty());
    verify_rotation(90, true);
    for (int angle : {180, 270, 0}) {
        // Both toolbar click and keyboard shortcut share this presentation path.
        key(SDLK_r, true); key(SDLK_r, false);
        events = take(); assert(events.size() == 1 && events[0].kind == LT_DESKTOP_ROTATE);
        verify_rotation(angle, true);
    }
    // An unchanged/paused guest frame must still visibly rotate immediately.
    lt_desktop_window_paused(&window, 1);
    key(SDLK_r, true); key(SDLK_r, false);
    events = take(); assert(events.size() == 1 && events[0].kind == LT_DESKTOP_ROTATE);
    verify_rotation(90, false);
    lt_desktop_window_paused(&window, 0);

    // Landscape-scanned panels (e.g. K48 iPad 1024x768: width > height) present upright (+90 CW)
    // when display_rotation == 0, and map contacts back to panel coordinates.
    while (window.display_rotation != 0) {
        key(SDLK_r, true); key(SDLK_r, false); take();
    }
    assert(lt_desktop_window_frame(&window, bgra.data(), 3, 2, 12) == 0);
    assert(lt_desktop_window_present(&window, 0, 0) == 0);
    assert(SDL_RenderReadPixels(window.renderer, nullptr, SDL_PIXELFORMAT_RGBA32, pixels.data(), 480 * 4) == 0);
    const auto ipad_view = window.layout().guest(3, 2, 90);
    for (int i = 0; i < 6; ++i) {
        const double gx = (i % 3 + .5) / 3, gy = (i / 3 + .5) / 2;
        const double u = 1 - gy, v = gx;
        const double px = ipad_view.left + u * ipad_view.width, py = ipad_view.top + v * ipad_view.height;
        const auto *pixel = pixels.data() + (int(py) * 480 + int(px)) * 4;
        assert(pixel[0] == colors[i][0] && pixel[1] == colors[i][1] && pixel[2] == colors[i][2] && pixel[3] == 255);
        window.pointer({1, 702}, 0, px, py);
        window.pointer({1, 702}, 2, px, py);
        const auto contacts = take();
        assert(contacts.size() == 2 && contacts[0].phase == 0 && contacts[1].phase == 2);
        assert(std::abs(contacts[0].x - gx) < 1e-8 && std::abs(contacts[0].y - gy) < 1e-8);
    }

    key(SDLK_ESCAPE, true); key(SDLK_ESCAPE, false);
    events = take(); assert(events.size() == 1 && events[0].kind == LT_DESKTOP_STOP);
    assert(!window.enabled && window.stopping);
    SDL_ShowCursor(SDL_DISABLE);
    window.dispatch(enter);
    assert(SDL_ShowCursor(SDL_QUERY) == SDL_ENABLE && take().empty());
    lt_desktop_window_enabled(&window, 1);
    assert(!window.enabled); // Closing does not silently restart a session.
    key(SDLK_h, true); assert(take().empty());
    assert(lt_desktop_window_frame(&window, nullptr, 320, 480, 1280) == -1);
    assert(lt_desktop_window_poll(nullptr, nullptr) == -1);
    SDL_DestroyTexture(window.texture);
    SDL_DestroyRenderer(window.renderer);
    SDL_FreeSurface(surface);
    SDL_DestroyWindow(window.window);
    SDL_QuitSubSystem(SDL_INIT_VIDEO | SDL_INIT_EVENTS);
    assert(!lt_desktop_window_create("requires hardware", 480, 800));
    assert(!active_window);
    assert(std::string(lt_desktop_window_error()).find("hardware") != std::string::npos);
    std::cout << "native shared adapter ownership/multitouch/cancel/quarter-turn pixels+input/stop/hardware refusal PASS; synthetic host only\n";
}
