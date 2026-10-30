#include "SharedFrameRead.hpp"
#include "lighttouch.h"
#include "../Portable/src/Elapsed.hpp"
#include "TouchScript.hpp"
#include "ControlDelivery.hpp"
#include "Presentation.hpp"
#include "ControlBar.hpp"
#include "../Desktop/ui/Cursor.hpp"
#include "ReplayQueue.hpp"
#include "Admission.hpp"
#include "ContactOwnership.hpp"
#include "AudioQueue.hpp"
#include "PauseFence.hpp"
#include <SDL.h>
#include <sys/socket.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <time.h>
#include <array>
#include <algorithm>
#include <sstream>
#include <chrono>
#include <cstring>
#include <cstdlib>
#include <cstdio>
#include <cerrno>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iostream>
#include <map>
#include <stdexcept>
#include <thread>
#include <vector>
namespace fs = std::filesystem;
static uint64_t now_ns() {
    timespec ts{};
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return uint64_t(ts.tv_sec) * 1000000000ull + uint64_t(ts.tv_nsec);
}
static void check(lt_status status, const lt_error &e) {
    if (status != LT_OK)
        throw std::runtime_error(e.message);
}
static void require(bool ok, const std::string &m) {
    if (!ok)
        throw std::runtime_error(m);
}
static volatile sig_atomic_t interrupt_requested = 0;
static void request_interrupt(int) { interrupt_requested = 1; }
struct InterruptGuard {
    struct sigaction previous {};
    InterruptGuard() {
        struct sigaction action {};
        action.sa_handler = request_interrupt;
        sigemptyset(&action.sa_mask);
        require(sigaction(SIGINT, &action, &previous) == 0, "install interrupt handler");
    }
    ~InterruptGuard() { sigaction(SIGINT, &previous, nullptr); }
};
static std::string child_start_ticks(pid_t pid) {
    std::ifstream file("/proc/" + std::to_string(pid) + "/stat");
    std::string line, token;
    std::getline(file, line);
    const auto end = line.rfind(')');
    if (end == std::string::npos)
        return "unavailable";
    std::istringstream fields(line.substr(end + 1));
    for (int i = 0; i < 20; ++i)
        if (!(fields >> token))
            return "unavailable";
    return token;
}
// Private inherited SOCK_SEQPACKET sockets: control/status and bounded PCM are
// separate channels, shared-frame bytes travel only through readonly memfd.
enum Kind : uint32_t {
    Hello = 1,
    Status = 2,
    Touch = 3,
    Button = 4,
    Pause = 5,
    Stop = 6,
    Cancel = 7,
    Motion = 8,
    Reply = 9,
    InputStatus = 10,
    GuestRequest = 11,
    GuestResult = 12,
    GuestCancel = 13,
    Screenshot = 14,
    AdmissionUpdate = 15,
    AdmissionCancel = 16,
    AdmissionFailure = 17
};
struct Packet {
    uint32_t size = sizeof(Packet), version = 1, kind = 0, reserved = 0;
    lt_runtime_status status{};
    lt_runtime_diagnostics diagnostics{};
    lt_runtime_io_stats io{};
    lt_input_status input_status{};
    lt_touch_batch touch{};
    lt_motion motion{};
    lt_error error{};
    lt_guest_result guest_result{};
    uint32_t guest_operation = 0;
    char guest_argument[1024]{};
    uint64_t guest_id = 0;
    uint64_t pcm_socket_dropped = 0, pcm_worker_discarded = 0, diagnostics_monotonic_ns = 0;
    uint64_t audio_epoch = 1, audio_command = 0;
    uint32_t audio_running = 0, pause_target = 0;
    uint32_t button = 0, value = 0;
    uint64_t mapping_bytes = 0;
    lt::AdmissionProgress admission{};
};
struct AudioPacket {
    uint32_t size = sizeof(AudioPacket), version = 1;
    uint64_t epoch = 1;
    lt_pcm_info info{sizeof(lt_pcm_info), 1, 0, 0, 0, 0, 0, 0};
    std::array<int16_t, 8192> samples{};
};
static bool send_packet(int socket, const Packet &p, int fd = -1) {
    iovec iov{const_cast<Packet *>(&p), sizeof p};
    msghdr message{};
    message.msg_iov = &iov;
    message.msg_iovlen = 1;
    char control[CMSG_SPACE(sizeof(int))]{};
    if (fd >= 0) {
        message.msg_control = control;
        message.msg_controllen = sizeof control;
        auto *c = CMSG_FIRSTHDR(&message);
        c->cmsg_level = SOL_SOCKET;
        c->cmsg_type = SCM_RIGHTS;
        c->cmsg_len = CMSG_LEN(sizeof(int));
        memcpy(CMSG_DATA(c), &fd, sizeof fd);
    }
    ssize_t n = sendmsg(socket, &message, MSG_DONTWAIT | MSG_NOSIGNAL);
    return n == sizeof p;
}
static bool receive(int socket, Packet &p, int *fd = nullptr) {
    iovec iov{&p, sizeof p};
    msghdr message{};
    message.msg_iov = &iov;
    message.msg_iovlen = 1;
    char control[CMSG_SPACE(sizeof(int))]{};
    message.msg_control = control;
    message.msg_controllen = sizeof control;
    ssize_t n = recvmsg(socket, &message, MSG_DONTWAIT | MSG_CMSG_CLOEXEC);
    if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR))
        return false;
    if (n == 0)
        throw std::runtime_error("worker control channel closed");
    require(n == sizeof p && !(message.msg_flags & (MSG_TRUNC | MSG_CTRUNC)) && p.size == sizeof p && p.version == 1,
            "invalid worker protocol");
    for (auto *c = CMSG_FIRSTHDR(&message); c; c = CMSG_NXTHDR(&message, c))
        if (c->cmsg_level == SOL_SOCKET && c->cmsg_type == SCM_RIGHTS) {
            require(c->cmsg_len == CMSG_LEN(sizeof(int)), "invalid frame FD");
            int passed = -1;
            memcpy(&passed, CMSG_DATA(c), sizeof passed);
            if (fd)
                *fd = passed;
            else
                close(passed);
        }
    return true;
}
static void peer(int socket) {
    ucred credentials{};
    socklen_t length = sizeof credentials;
    require(getsockopt(socket, SOL_SOCKET, SO_PEERCRED, &credentials, &length) == 0 && credentials.uid == geteuid(),
            "worker peer UID mismatch");
}
struct Options {
    std::string base, state, rom, engine, package, import, finalize_import, sha, screenshot, script, library, record, name,
        set_guest_package;
    bool recover = false, headless = false, audio = true, worker = false, list = false, library_operation = false;
    bool debug_qmp = false, trace_io = false, debug_touch_trace = false;
    int control = -1, pcm = -1;
    double seconds = 0;
};
static Options options(int argc, char **argv) {
    Options o;
    std::map<std::string, std::string *> fields = {
        {"--base", &o.base},       {"--state", &o.state},           {"--rom", &o.rom},
        {"--engine", &o.engine},   {"--package", &o.package},       {"--import", &o.import},
        {"--finalize-import", &o.finalize_import},
        {"--library", &o.library}, {"--record", &o.record},         {"--name", &o.name},
        {"--sha256", &o.sha},      {"--screenshot", &o.screenshot}, {"--script", &o.script},
        {"--set-guest-package", &o.set_guest_package}};
    for (int i = 1; i < argc; i++) {
        std::string key = argv[i];
        if (fields.count(key)) {
            require(i + 1 < argc, "missing " + key);
            *fields[key] = argv[++i];
        } else if (key == "--list")
            o.list = true;
        else if (key == "--recover")
            o.recover = true;
        else if (key == "--headless")
            o.headless = true;
        else if (key == "--no-audio")
            o.audio = false;
        else if (key == "--debug-touch-trace")
            o.debug_touch_trace = true;
        else if (key == "--trace-io")
            o.trace_io = true;
        else if (key == "--debug-qmp")
            o.debug_qmp = true;
        else if (key == "--seconds") {
            require(i + 1 < argc, "missing duration");
            o.seconds = std::stod(argv[++i]);
            require(o.seconds >= 0, "invalid duration");
        } else if (key == "--worker") {
            require(i + 2 < argc, "missing worker descriptors");
            o.worker = true;
            o.control = std::stoi(argv[++i]);
            o.pcm = std::stoi(argv[++i]);
        } else if (key == "--help") {
            std::cout
                << "lighttouch-linux --base DIR --state DIR --engine LIB [--rom FILE] [--package ITPACK]\n  [--import "
                   "ITPACK --sha256 HASH] [--recover] [--headless --seconds N]\n"
                   "  lighttouch-linux --finalize-import STAGE --base DEST\n"
                   "  lighttouch-linux --library DIR --record ID --set-guest-package ITPACK (keeps the device)\n  [--script FILE] [--screenshot BMP] "
                   "[--no-audio] [--trace-io] [--debug-touch-trace]\n\nMouse left/right: contacts 1/2. "
                << lt::desktop_shortcut_help() << "\n"
                << "Visible controls below the guest mirror these shortcuts. "
                   "Escape: cancel admission or orderly "
                   "stop. Validation:900s absolute/30s checkpoint budget; Ctrl+C cancels or stops.\nC: release all "
                   "contacts. F5: pinch in. F6: labeled two-contact pinch. F7: "
                   "crossing/independent lift. "
                   "Arrows: acceleration replay (not hardware "
                   "gyro).\nScript: seconds touch ID phase x y; button ID down; pause 0/1; cancel; stop.\n";
            std::exit(0);
        } else
            throw std::runtime_error("unknown option: " + key);
    }
    require(!o.base.empty() || !o.library.empty(), "--base or --library required");
    require(o.finalize_import.empty() || (!o.base.empty() && o.import.empty() && o.library.empty() &&
                o.engine.empty() && !o.worker), "--finalize-import requires only a stage and --base destination");
    if (o.state.empty() && !o.base.empty())
        o.state = fs::absolute(o.base).parent_path().string() + "/state";
    for (auto *p : {&o.base, &o.state, &o.rom, &o.engine, &o.package, &o.import, &o.finalize_import,
                   &o.screenshot, &o.script, &o.library, &o.set_guest_package})
        if (!p->empty())
            *p = fs::absolute(*p).string();
    return o;
}
static void prepare_library(Options &o) {
    if (o.library.empty())
        return;
    lt_error e{sizeof(e), 1, 0, {}};
    lt_library *l = nullptr;
    lt_library_config c{sizeof(c), 1, o.library.c_str()};
    check(lt_library_open(&c, &l, &e), e);
    struct Handle {
        lt_library *l;
        ~Handle() { lt_library_close(l); }
    } handle{l};
    lt_record_info info{};
    info.size = sizeof(info);
    info.version = 1;
    if (!o.worker && !o.import.empty()) {
        lt_library_import_config cfg{sizeof(cfg),
                                     1,
                                     o.import.c_str(),
                                     o.sha.empty() ? nullptr : o.sha.c_str(),
                                     o.name.empty() ? nullptr : o.name.c_str(),
                                     o.rom.empty() ? nullptr : o.rom.c_str(),
                                     o.package.empty() ? nullptr : o.package.c_str(),
                                     0,
                                     nullptr,
                                     nullptr};
        check(lt_library_import(l, &cfg, &info, &e), e);
        o.record = info.id;
        o.import.clear();
        o.library_operation = true;
        std::cout << "imported record " << info.id << " " << info.board << " " << info.build << "\n";
    }
    if (!o.worker && !o.set_guest_package.empty()) {
        require(!o.record.empty(), "--set-guest-package needs --record");
        check(lt_library_set_guest_package(l, o.record.c_str(), o.set_guest_package.c_str(), &info, &e), e);
        std::cout << "record " << info.id << " guest package replaced; it installs at the next boot\n";
        o.library_operation = true;
        return;
    }
    if (!o.worker && (o.list || (o.engine.empty() && o.record.empty()))) {
        uint32_t count = 0;
        check(lt_library_count(l, &count, &e), e);
        for (uint32_t i = 0; i < count; i++) {
            check(lt_library_record_at(l, i, &info, &e), e);
            std::cout << info.id << "\t" << info.display_name << "\t" << info.board << "-" << info.build << "\t"
                      << (info.selected ? "selected" : "") << "\t" << (info.dirty ? "dirty" : "clean") << "\n";
        }
        o.library_operation = true;
        if (o.record.empty())
            return;
    }
    if (!o.record.empty())
        check(lt_library_select(l, o.record.c_str(), &e), e);
    check(lt_library_selected(l, &info, &e), e);
    o.record = info.id;
    o.base = info.base_path;
    o.state = info.state_path;
    if (o.rom.empty())
        o.rom = info.bootrom_path;
    if (o.package.empty())
        o.package = info.guest_package_path;
}
static int worker(const Options &o) {
    InterruptGuard interrupts;
    peer(o.control);
    peer(o.pcm);
    lt_error error{sizeof(error), 1, 0, {}};
    lt_device *d = nullptr;
    lt_runtime *r = nullptr;
    struct PrestartHandles {
        lt_device *&device;
        lt_runtime *&runtime;
        bool started = false;
        bool release() {
            if (started)
                return false; // Never destroy/close an active guest as admission cancellation.
            bool released = !runtime;
            if (runtime) {
                lt_error cleanup{sizeof(cleanup), 1, 0, {}};
                released = lt_runtime_destroy(runtime, &cleanup) == LT_OK;
                if (released)
                    runtime = nullptr;
            }
            if (released && device) {
                lt_device_close(device);
                device = nullptr;
            }
            return released;
        }
        ~PrestartHandles() {
            if (!started)
                release();
        }
    } prestart{d, r};
    lt_device_config dc{sizeof(dc), 1, o.base.c_str(), o.state.c_str(), uint32_t(o.recover)};
    lt::AdmissionObserver admission(
        now_ns,
        [&] {
            if (interrupt_requested)
                return true;
            Packet incoming;
            for (int budget = 0; budget < 32 && receive(o.control, incoming); ++budget) {
                require(incoming.kind == AdmissionCancel, "unexpected command during admission");
                return true;
            }
            return false;
        },
        [&](const lt::AdmissionProgress &progress) {
            Packet update;
            update.kind = AdmissionUpdate;
            update.admission = progress;
            return send_packet(o.control, update);
        });
    auto fail_admission = [&](lt_status status) {
        if (!prestart.release()) {
            status = LT_ENGINE;
            std::snprintf(error.message, sizeof(error.message),
                          "unstarted runtime did not release; process disposal required; state retained");
        }
        Packet failure;
        failure.kind = AdmissionFailure;
        failure.error = error;
        failure.error.code = status;
        if (status == LT_CANCELLED && !admission.reason.empty())
            std::snprintf(failure.error.message, sizeof(failure.error.message), "%s", admission.reason.c_str());
        send_packet(o.control, failure);
        std::cerr << "admission failed code=" << status << " message=" << failure.error.message << std::endl;
        return status == LT_CANCELLED ? 130 : 2;
    };
    lt_status admitted = LT_OK;
    if (o.library.empty())
        admitted = lt_device_open_observed(&dc, lt::AdmissionObserver::notify, &admission, &d, &error);
    else {
        lt_library *l = nullptr;
        lt_library_config cfg{sizeof(cfg), 1, o.library.c_str()};
        admitted = lt_library_open(&cfg, &l, &error);
        if (admitted == LT_OK)
            admitted = lt_library_device_open_observed(l, o.record.c_str(), uint32_t(o.recover),
                                                       lt::AdmissionObserver::notify, &admission, &d, &error);
        if (l)
            lt_library_close(l);
    }
    if (admitted != LT_OK)
        return fail_admission(admitted);
    if (admission.checkpoint(admission.progress.done, admission.progress.total, true))
        return fail_admission(LT_CANCELLED);
    std::string serial = o.state + "/serial.log";
    lt_runtime_config config{sizeof(config),
                             1,
                             o.engine.c_str(),
                             d,
                             {sizeof(lt_boot_config), 1, nullptr, o.rom.empty() ? nullptr : o.rom.c_str(),
                              o.package.empty() ? nullptr : o.package.c_str(), serial.c_str(), uint32_t(o.audio), 0}};
    admitted = lt_runtime_create(&config, &r, &error);
    if (admitted != LT_OK)
        return fail_admission(admitted);
    if (admission.checkpoint(admission.progress.done, admission.progress.total, true))
        return fail_admission(LT_CANCELLED);
    if (o.debug_touch_trace) {
        admitted = lt_runtime_debug_touch_trace_enable(r, &error);
        if (admitted != LT_OK)
            return fail_admission(admitted);
        std::cerr << "debug_touch_trace worker_pid=" << getpid()
                  << " fixed_event=ipod_touch_multitouch_log clock=guest_virtual_seconds\n";
    }
    if (o.debug_qmp) {
        admitted = lt_runtime_debug_qmp_enable(r, &error);
        if (admitted != LT_OK)
            return fail_admission(admitted);
        char path[1024];
        admitted = lt_runtime_debug_qmp_path(r, path, sizeof(path), &error);
        if (admitted != LT_OK)
            return fail_admission(admitted);
        std::cerr << "debug_qmp worker_pid=" << getpid() << " private_path=" << path << "\n";
    }
    Packet hello;
    hello.kind = Hello;
    int fd = -1;
    admitted = lt_runtime_frame_fd(r, &fd, &hello.mapping_bytes, &error);
    if (admitted != LT_OK)
        return fail_admission(admitted);
    if (admission.checkpoint(admission.progress.done, admission.progress.total, true)) {
        close(fd);
        return fail_admission(LT_CANCELLED);
    }
    const uint64_t hello_attempt = now_ns();
    while (!send_packet(o.control, hello, fd)) {
        if (admission.checkpoint(admission.progress.done, admission.progress.total, true)) {
            close(fd);
            return fail_admission(LT_CANCELLED);
        }
        if (lt::admission_elapsed(now_ns(), hello_attempt, 2000000000ull)) {
            close(fd);
            std::snprintf(error.message, sizeof(error.message), "send verified admission frame FD deadline");
            return fail_admission(LT_IO);
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    close(fd);
    // A cancellation racing HELLO is handled as ordinary Stop once start succeeds.
    check(lt_runtime_start(r, &error), error);
    prestart.started = true;
    uint64_t last_status = 0, stopping_since = 0, reported_input = 0, pending_guest = 0, pcm_socket_dropped = 0;
    uint64_t audio_epoch = 1, audio_command = 0;
    uint64_t pcm_worker_discarded = 0;
    bool audio_suspended = false;
    lt::PauseFence pause_fence;
    for (;;) {
        if (interrupt_requested && !stopping_since) {
            check(lt_runtime_request_shutdown(r, &error), error);
            stopping_since = now_ns();
        }
        Packet p;
        for (int budget = 0; budget < 32 && receive(o.control, p); budget++) {
            lt_status result = LT_INVALID;
            switch (p.kind) {
            case Touch:
                result = lt_runtime_touch(r, &p.touch, &error);
                if (o.trace_io) {
                    lt_input_status admitted{sizeof(admitted), 1, 0, 0, 0};
                    lt_error trace_error{sizeof(trace_error), 1, 0, {}};
                    auto status = lt_runtime_input_status(r, &admitted, &trace_error);
                    std::ostringstream line;
                    line << "trace_touch observed_monotonic_ns=" << now_ns() << " result=" << result
                         << " request=" << (status == LT_OK ? admitted.request_id : 0) << " contacts=" << p.touch.count;
                    for (uint32_t index = 0; index < std::min(p.touch.count, LT_MAX_CONTACTS); ++index) {
                        const auto &contact = p.touch.contacts[index];
                        line << " contact=" << contact.id << ":" << contact.phase << ":" << contact.x << ":"
                             << contact.y;
                    }
                    std::cout << line.str() << std::endl;
                }
                break;
            case Button:
                result = lt_runtime_button(r, p.button, p.value, &error);
                break;
            case Pause:
                if (!p.value && pause_fence.defer_resume(p.audio_command)) {
                    result = LT_OK;
                    break;
                }
                result = lt_runtime_pause(r, p.value, &error);
                if (result == LT_OK) {
                    ++audio_epoch;
                    audio_command = p.audio_command;
                    audio_suspended = p.value != 0;
                    if (p.value)
                        pause_fence.pause_admitted();
                    last_status = 0;
                }
                break;
            case AdmissionCancel:
            case Stop:
                result = lt_runtime_request_shutdown(r, &error);
                if (result == LT_OK && !stopping_since)
                    stopping_since = now_ns();
                break;
            case Cancel:
                result = lt_runtime_cancel_input(r, &error);
                break;
            case Motion:
                result = lt_runtime_motion(r, &p.motion, &error);
                break;
            case GuestRequest: {
                lt_guest_request request{sizeof(request), 1, p.guest_operation, 65000, p.guest_argument};
                result = lt_runtime_guest_request(r, &request, &pending_guest, &error);
                break;
            }
            case GuestCancel:
                result = lt_runtime_guest_cancel(r, p.guest_id, &error);
                break;
            default:
                break;
            }
            if (o.trace_io && (p.kind == Cancel || p.kind == Pause))
                std::cout << "trace_control observed_monotonic_ns=" << now_ns() << " kind=" << p.kind
                          << " value=" << p.value << " result=" << result << std::endl;
            if (result != LT_OK) {
                Packet reply;
                reply.kind = Reply;
                reply.reserved = p.kind;
                reply.error = error;
                send_packet(o.control, reply);
            }
        }
        lt_input_status input{sizeof(input), 1, 0, 0, 0};
        if (lt_runtime_input_status(r, &input, &error) == LT_OK && input.request_id && input.state != 1 &&
            input.request_id != reported_input) {
            reported_input = input.request_id;
            if (o.trace_io)
                std::cout << "trace_applied observed_monotonic_ns=" << now_ns() << " request=" << input.request_id
                          << " state=" << input.state << " engine_result=" << input.engine_result << std::endl;
            Packet report;
            report.kind = InputStatus;
            report.input_status = input;
            if (input.state == 3) {
                lt_runtime_cancel_input(r, &error);
                report.error = {sizeof(lt_error), 1, LT_INVALID, {}};
                snprintf(report.error.message, sizeof(report.error.message),
                         "touch batch %llu rejected by engine (%d); all contacts released",
                         static_cast<unsigned long long>(input.request_id), input.engine_result);
            }
            send_packet(o.control, report);
        }
        if (pending_guest) {
            lt_guest_result guest{sizeof(guest), 1, 0, 0, 0, 0, 0, {}};
            lt_status result = lt_runtime_guest_poll(r, pending_guest, &guest, &error);
            if (result != LT_OK || guest.state != 1) {
                Packet reply;
                reply.kind = GuestResult;
                reply.guest_result = guest;
                if (result != LT_OK)
                    reply.error = error;
                send_packet(o.control, reply);
                pending_guest = 0;
            }
        }
        lt_runtime_status status{sizeof(status), 1, 0, 0, 0, 0, 0, 0};
        lt_status result = lt_runtime_poll(r, &status, &error);
        const lt_error poll_error = error;
        uint64_t resume_command = 0;
        if (pause_fence.resume_ready(status.state == LT_PAUSED,
                                     stopping_since || status.state == LT_STOPPING || status.state == LT_STOPPED ||
                                         status.state == LT_FAILED,
                                     resume_command)) {
            const auto resumed = lt_runtime_pause(r, 0, &error);
            if (resumed == LT_OK) {
                ++audio_epoch;
                audio_command = resume_command;
                audio_suspended = false;
                last_status = 0;
            } else {
                Packet reply;
                reply.kind = Reply;
                reply.reserved = Pause;
                reply.error = error;
                send_packet(o.control, reply);
            }
        }
        uint64_t now = now_ns();
        if (now - last_status >= 250000000 || status.state == LT_STOPPED || status.state == LT_FAILED) {
            Packet update;
            update.kind = Status;
            update.status = status;
            update.pcm_socket_dropped = pcm_socket_dropped;
            update.pcm_worker_discarded = pcm_worker_discarded;
            update.audio_epoch = audio_epoch;
            update.audio_command = audio_command;
            update.pause_target = audio_suspended;
            update.audio_running = o.audio && !audio_suspended && status.state == LT_RUNNING;
            update.diagnostics = {sizeof(lt_runtime_diagnostics), 1, 0, 0, 0, 0, 0, 0, 0, 0};
            lt_runtime_diagnose(r, &update.diagnostics, &error);
            update.diagnostics_monotonic_ns = now_ns();
            update.io.size = sizeof(update.io);
            update.io.version = 1;
            lt_runtime_io_statistics(r, &update.io, &error);
            if (result != LT_OK)
                update.error = poll_error;
            send_packet(o.control, update);
            last_status = now;
        }
        if (status.state == LT_STOPPED) {
            check(lt_runtime_destroy(r, &error), error);
            r = nullptr;
            lt_device_close(d);
            d = nullptr;
            return status.guest_shutdown_confirmed ? 0 : 2;
        }
        if (status.state == LT_FAILED) {
            std::cerr << "runtime failed: " << poll_error.message << "; dirty state retained\n";
            return 2;
        }
        if (o.audio) {
            for (int budget = 0; budget < 8; budget++) {
                AudioPacket pcm;
                pcm.epoch = audio_epoch;
                lt_status res = lt_runtime_pcm(r, pcm.samples.data(), 4096, &pcm.info, &error);
                if (res != LT_OK)
                    break;
                if (audio_suspended || status.state != LT_RUNNING)
                    pcm_worker_discarded += pcm.info.frames;
                else if (send(o.pcm, &pcm, sizeof pcm, MSG_DONTWAIT | MSG_NOSIGNAL) != sizeof pcm)
                    pcm_socket_dropped += pcm.info.frames;
            }
        }
        if (stopping_since && lt::elapsed_exceeds(now_ns(), stopping_since, lt::worker_shutdown_timeout_ns)) {
            std::cerr << "guest shutdown timeout; dirty state retained\n";
            return 3;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
}
struct Script {
    double at;
    Packet packet;
    bool replay = false;
};
static std::vector<Script> script_file(const std::string &path) {
    std::vector<Script> script;
    if (path.empty())
        return script;
    std::ifstream f(path);
    require(bool(f), "script missing");
    std::string line;
    double previous = -1;
    while (std::getline(f, line)) {
        if (line.empty() || line[0] == '#')
            continue;
        std::istringstream input(line);
        Script s{};
        std::string cmd;
        require(bool(input >> s.at >> cmd) && s.at >= previous, "invalid script order");
        previous = s.at;
        auto &p = s.packet;
        if (cmd == "touch" || cmd == "touches") {
            p.kind = Touch;
            uint32_t count = 1;
            if (cmd == "touches")
                require(bool(input >> count), "script touches missing count");
            p.touch = lt::parse_touch_contacts(input, count);
        } else if (cmd == "button") {
            p.kind = Button;
            require(bool(input >> p.button >> p.value), "invalid button");
        } else if (cmd == "pause") {
            p.kind = Pause;
            require(bool(input >> p.value), "invalid pause");
        } else if (cmd == "screenshot") {
            p.kind = Screenshot;
            std::string path;
            std::getline(input >> std::ws, path);
            require(fs::path(path).is_absolute() && path.size() < sizeof(p.guest_argument),
                    "screenshot needs bounded private absolute path");
            memcpy(p.guest_argument, path.c_str(), path.size() + 1);
        } else if (cmd == "guest") {
            p.kind = GuestRequest;
            std::string operation, argument;
            require(bool(input >> operation), "missing guest operation");
            if (operation == "ping")
                p.guest_operation = LT_GUEST_PING;
            else if (operation == "frontmost")
                p.guest_operation = LT_GUEST_FRONTMOST;
            else if (operation == "launch")
                p.guest_operation = LT_GUEST_LAUNCH_BUILTIN;
            else if (operation == "type")
                p.guest_operation = LT_GUEST_TYPE_TEXT;
            else if (operation == "sync")
                p.guest_operation = LT_GUEST_SYNC;
            else if (operation == "gyro-probe")
                p.guest_operation = LT_GUEST_LAUNCH_GYRO_PROBE;
            else
                throw std::runtime_error("unknown typed guest operation");
            std::getline(input >> std::ws, argument);
            require(argument.size() < sizeof(p.guest_argument), "guest script argument too long");
            memcpy(p.guest_argument, argument.c_str(), argument.size() + 1);
        } else if (cmd == "motion") {
            p.kind = Motion;
            p.motion = {sizeof(lt_motion), 1, 0, 0, 0, {}, {}};
            require(bool(input >> p.motion.kinds >> p.motion.acceleration[0] >> p.motion.acceleration[1] >>
                         p.motion.acceleration[2] >> p.motion.angular_velocity[0] >> p.motion.angular_velocity[1] >>
                         p.motion.angular_velocity[2]),
                    "invalid labeled motion replay");
        } else if (cmd == "cancel")
            p.kind = Cancel;
        else if (cmd == "stop")
            p.kind = Stop;
        else
            throw std::runtime_error("unknown script command");
        script.push_back(s);
    }
    return script;
}
static bool frame_copy(const lt_shared_frame *shared, std::vector<uint8_t> &pixels, lt_frame_info &frame,
                       uint64_t &sequence) {
    for (int attempt = 0; attempt < 3; attempt++) {
        uint64_t before = __atomic_load_n(&shared->generation, __ATOMIC_SEQ_CST);
        if (before & 1)
            continue;
        auto f = shared->frame;
        if (!f.sequence || f.sequence == sequence)
            return false;
        require(f.version == 1 && f.size == sizeof f && f.bytes <= LT_FRAME_CAPACITY && f.stride >= f.width * 4ull &&
                    f.bytes >= uint64_t(f.stride) * f.height && f.width <= 4096 && f.height <= 4096,
                "invalid shared frame bounds");
        pixels.resize(size_t(f.bytes));
        memcpy(pixels.data(), reinterpret_cast<const uint8_t *>(shared) + sizeof(*shared), size_t(f.bytes));
        uint64_t after = __atomic_load_n(&shared->generation, __ATOMIC_SEQ_CST);
        if (before == after && !(after & 1)) {
            frame = f;
            sequence = f.sequence;
            return true;
        }
    }
    return false;
}
static int frontend(const Options &o, int argc, char **argv) {
    if (!o.import.empty() || !o.finalize_import.empty()) {
        lt_error e{sizeof(e), 1, 0, {}};
        struct ImportLog {
            std::string phase;
            int percent = -1;
        } log;
        lt_import_config config{sizeof(config),
                                1,
                                o.import.c_str(),
                                o.base.c_str(),
                                o.sha.c_str(),
                                0,
                                nullptr,
                                nullptr};
        auto progress = [](void *opaque, const char *phase, uint64_t done, uint64_t total) {
            auto &log = *static_cast<ImportLog *>(opaque);
            int percent = total ? int((static_cast<long double>(done) * 100) / total) : 0;
            if (log.phase != phase || log.percent != percent) {
                std::cerr << "import phase=" << phase << " percent=" << percent << " done=" << done
                          << " total=" << total << "\n";
                log.phase = phase;
                log.percent = percent;
            }
            return interrupt_requested ? 1 : 0;
        };
        if (!o.finalize_import.empty()) {
            lt_finalize_import_config finalize{sizeof(finalize), 1, o.finalize_import.c_str(), o.base.c_str()};
            check(lt_finalize_import_observed(&finalize, progress, &log, &e), e);
        } else
            check(fs::is_directory(o.import) ? lt_import_directory_observed(&config, progress, &log, &e)
                                            : lt_import_archive_observed(&config, progress, &log, &e), e);
    }
    if (o.engine.empty() && (!o.import.empty() || !o.finalize_import.empty())) {
        std::cout << "prepared base imported: " << o.base << "\n";
        return 0;
    }
    require(!o.engine.empty(), "--engine required for session");
    InterruptGuard interrupts;
    const uint64_t admission_started = now_ns();
    int sockets[2], audio[2];
    require(socketpair(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0, sockets) == 0, "control socketpair");
    require(socketpair(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0, audio) == 0, "audio socketpair");
    pid_t pid = fork();
    require(pid >= 0, "worker fork");
    if (pid == 0) {
        close(sockets[0]);
        close(audio[0]);
        fcntl(sockets[1], F_SETFD, 0);
        fcntl(audio[1], F_SETFD, 0);
        std::string control = std::to_string(sockets[1]), pcm = std::to_string(audio[1]);
        std::vector<char *> args;
        for (int i = 0; i < argc; i++)
            args.push_back(argv[i]);
        if (!o.record.empty()) {
            args.push_back(const_cast<char *>("--record"));
            args.push_back(const_cast<char *>(o.record.c_str()));
        }
        args.push_back(const_cast<char *>("--worker"));
        args.push_back(control.data());
        args.push_back(pcm.data());
        args.push_back(nullptr);
        execv("/proc/self/exe", args.data());
        _exit(127);
    }
    close(sockets[1]);
    close(audio[1]);
    struct Child {
        pid_t pid;
        int control, audio, status = 0;
        std::string ticks;
        bool reaped = false, disposed = false, termination_sent = false;
        bool wait_bounded(uint64_t budget) {
            const uint64_t began = now_ns();
            do {
                const pid_t found = waitpid(pid, &status, WNOHANG);
                if (found == pid) {
                    reaped = true;
                    pid = -1;
                    return true;
                }
                if (found < 0 && errno != EINTR) {
                    pid = -1;
                    return false;
                }
                std::this_thread::sleep_for(std::chrono::milliseconds(10));
            } while (!lt::admission_elapsed(now_ns(), began, budget));
            return false;
        }
        void dispose() {
            if (disposed)
                return;
            disposed = true;
            if (control >= 0)
                close(control);
            if (audio >= 0)
                close(audio);
            control = audio = -1;
            if (pid <= 0 || wait_bounded(100000000ull))
                return;
            if (pid <= 0)
                return; // No longer an unreaped child; never signal a reused PID.
            termination_sent = true;
            kill(pid, SIGTERM);
            if (wait_bounded(500000000ull) || pid <= 0)
                return;
            kill(pid, SIGKILL);
            if (!wait_bounded(2000000000ull) && pid > 0)
                std::cerr << "worker disposal pending pid=" << pid << " start_ticks=" << ticks
                          << "; lease/state may remain owned; no clean exit inferred" << std::endl;
        }
        ~Child() { dispose(); }
    } child{pid, sockets[0], audio[0], 0, child_start_ticks(pid)};
    struct FinalReceipt {
        Child &child;
        pid_t worker;
        lt_runtime_status latest{};
        bool status_available = false;
        int frontend_return = -1;
        ~FinalReceipt() {
            child.dispose();
            const int worker_exit = !child.reaped ? -1 : WIFEXITED(child.status) ? WEXITSTATUS(child.status) : -2;
            std::cout << "FINAL observed_monotonic_ns=" << now_ns() << " worker_pid=" << worker
                      << " start_ticks=" << child.ticks << " status_available=" << status_available
                      << " state=" << (status_available ? int(latest.state) : -1)
                      << " confirmed=" << (status_available ? int(latest.guest_shutdown_confirmed) : -1)
                      << " dirty=" << (status_available ? int(latest.dirty) : -1) << " worker_reaped=" << child.reaped
                      << " worker_exit=" << worker_exit << " worker_disposal_requested=" << child.termination_sent
                      << " frontend_return=" << frontend_return << std::endl;
        }
    } final_receipt{child, pid};
    peer(sockets[0]);
    peer(audio[0]);
    std::cout << "admission worker_pid=" << pid << " start_ticks=" << child.ticks
              << " parent_started_monotonic_ns=" << admission_started
              << " absolute_budget_ns=" << lt::admission_absolute_ns
              << " checkpoint_stall_budget_ns=" << lt::admission_stall_ns << std::endl;
    struct Sdl {
        bool initialized = false;
        SDL_Window *window = nullptr;
        SDL_Renderer *renderer = nullptr;
        SDL_Texture *texture = nullptr;
        SDL_AudioDeviceID sound = 0;
        void release() {
            if (sound)
                SDL_CloseAudioDevice(sound);
            if (texture)
                SDL_DestroyTexture(texture);
            if (renderer)
                SDL_DestroyRenderer(renderer);
            if (window)
                SDL_DestroyWindow(window);
            sound = 0;
            texture = nullptr;
            renderer = nullptr;
            window = nullptr;
            if (initialized)
                SDL_Quit();
            initialized = false;
        }
        ~Sdl() { release(); }
    } sdl;
    SDL_Window *&window = sdl.window;
    SDL_Renderer *&renderer = sdl.renderer;
    SDL_Texture *&texture = sdl.texture;
    SDL_AudioDeviceID &sound = sdl.sound;
    std::string last_window_title = "LightTouch - starting";
    auto set_window_title = [&](const std::string &title) {
        if (window && title != last_window_title) {
            SDL_SetWindowTitle(window, title.c_str());
            last_window_title = title;
        }
    };
    if (!o.headless) {
        sdl.initialized = true; // SDL_Quit also cleans a partially failed init.
        require(SDL_Init(SDL_INIT_VIDEO | SDL_INIT_EVENTS) == 0, SDL_GetError());
        SDL_Rect available{};
        int initial_width = 480, initial_height = 800;
        if (SDL_GetDisplayUsableBounds(0, &available) == 0 && available.w > 0 && available.h > 0) {
            initial_width = std::min(initial_width, std::max(320, available.w - 48));
            initial_height = std::min(initial_height, std::max(240, available.h - 64));
        }
        window = SDL_CreateWindow(last_window_title.c_str(), SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
                                  initial_width, initial_height,
                                  SDL_WINDOW_RESIZABLE | SDL_WINDOW_ALLOW_HIGHDPI);
        require(window, SDL_GetError());
        SDL_SetWindowMinimumSize(window, 320, 240);
        lt::desktop_cursor(window);
        renderer = SDL_CreateRenderer(window, -1, SDL_RENDERER_ACCELERATED);
        if (!renderer)
            renderer = SDL_CreateRenderer(window, -1, SDL_RENDERER_SOFTWARE);
        require(renderer, SDL_GetError());
        SDL_RendererInfo info{};
        require(SDL_GetRendererInfo(renderer, &info) == 0, SDL_GetError());
        std::cout << "SDL renderer=" << info.name << " opaque_format=BGRX32\n";
    }
    Packet hello;
    int fd = -1;
    lt::AdmissionWatch admission(admission_started);
    bool admission_cancelled = false, cancel_sent = false;
    uint64_t cancel_since = 0;
    auto cancel_admission = [&](const char *reason) {
        if (!admission_cancelled) {
            admission_cancelled = true;
            cancel_since = now_ns();
            std::cout << "admission cancel_requested_monotonic_ns=" << cancel_since << " reason=" << reason
                      << std::endl;
        }
    };
    for (;;) {
        if (!o.headless) {
            SDL_Event event;
            while (SDL_PollEvent(&event))
                if (event.type == SDL_QUIT || (event.type == SDL_KEYDOWN && event.key.keysym.sym == SDLK_ESCAPE))
                    cancel_admission("user");
        }
        if (interrupt_requested)
            cancel_admission("interrupt");
        const uint64_t current = now_ns();
        if (admission.absolute_expired(current))
            cancel_admission("absolute-deadline");
        else if (admission.stalled(current))
            cancel_admission("checkpoint-stall");
        if (admission_cancelled && !cancel_sent) {
            Packet request;
            request.kind = AdmissionCancel;
            cancel_sent = send_packet(sockets[0], request);
        }
        if (admission_cancelled && lt::admission_elapsed(current, cancel_since, lt::admission_cancel_grace_ns))
            throw std::runtime_error("admission cancellation deadline; disposing only owned worker; state retained");
        Packet incoming;
        int passed = -1;
        if (receive(sockets[0], incoming, &passed)) {
            if (incoming.kind == Hello) {
                require(passed >= 0 && incoming.mapping_bytes == sizeof(lt_shared_frame) + LT_FRAME_CAPACITY,
                        "worker handshake invalid");
                hello = incoming;
                fd = passed;
                break; // Start can race this handoff; cancellation follows ordinary Stop below.
            }
            if (passed >= 0) {
                close(passed);
                throw std::runtime_error("unexpected admission frame FD");
            }
            if (incoming.kind == AdmissionFailure) {
                std::ostringstream message;
                message << "admission failed native_code=" << incoming.error.code << " message="
                        << std::string(incoming.error.message,
                                       strnlen(incoming.error.message, sizeof(incoming.error.message)));
                throw std::runtime_error(message.str());
            }
            require(incoming.kind == AdmissionUpdate, "unexpected admission packet");
            const uint64_t received = now_ns();
            admission.observe(incoming.admission, received);
            const auto &progress = admission.latest();
            std::cout << "admission observed_monotonic_ns=" << received
                      << " worker_monotonic_ns=" << progress.worker_monotonic_ns
                      << " checkpoint_sequence=" << progress.sequence << " done=" << progress.done
                      << " total=" << progress.total << " phase=" << lt::admission_phase_name(progress.phase)
                      << " worker_pid=" << pid << " start_ticks=" << child.ticks << std::endl;
            if (window) {
                const std::string title = "LightTouch - validating prepared device: " + std::to_string(progress.done) +
                                          "/" + std::to_string(progress.total) + " bytes - Escape cancels";
                set_window_title(title);
            }
        }
        if (renderer) {
            SDL_SetRenderDrawColor(renderer, 24, 24, 28, 255);
            SDL_RenderClear(renderer);
            if (admission.latest().total) {
                int width = 0, height = 0;
                SDL_GetRendererOutputSize(renderer, &width, &height);
                SDL_Rect bar{width / 10, height / 2,
                             int(width * .8 * double(admission.latest().done) / double(admission.latest().total)), 12};
                SDL_SetRenderDrawColor(renderer, 80, 160, 240, 255);
                SDL_RenderFillRect(renderer, &bar);
            }
            SDL_RenderPresent(renderer);
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    auto *shared =
        static_cast<const lt_shared_frame *>(mmap(nullptr, size_t(hello.mapping_bytes), PROT_READ, MAP_SHARED, fd, 0));
    close(fd);
    require(shared != MAP_FAILED, "map shared guest frame");
    require(shared->size == sizeof(*shared) && shared->version == 1 && shared->capacity == LT_FRAME_CAPACITY,
            "frame ABI mismatch");
    std::cout << "admission hello_verified_observed_monotonic_ns=" << now_ns() << " worker_pid=" << pid
              << " start_ticks=" << child.ticks << " mapping_bytes=" << hello.mapping_bytes
              << "; guest readiness still pending" << std::endl;
    set_window_title("LightTouch - starting guest");
    struct Mapping {
        const void *p;
        size_t n;
        ~Mapping() { munmap(const_cast<void *>(p), n); }
    } mapping{shared, size_t(hello.mapping_bytes)};
    std::string audio_failure;
    SDL_AudioSpec audio_spec{};
    if (o.audio) {
        sdl.initialized = true;
        const bool initialized = SDL_InitSubSystem(SDL_INIT_AUDIO) == 0;
        SDL_AudioSpec want{};
        want.freq = 44100;
        want.format = AUDIO_S16LSB;
        want.channels = 2;
        want.samples = 1024;
        if (initialized)
            sound = SDL_OpenAudioDevice(nullptr, 0, &want, &audio_spec, 0);
        if (!sound)
            audio_failure = std::string("SDL audio initialization/open failed: ") + SDL_GetError();
        else if (audio_spec.freq != int(lt::AudioQueue::rate) || audio_spec.channels != 2 ||
                 audio_spec.format != AUDIO_S16LSB)
            audio_failure = "SDL opened an incompatible PCM specification";
        // Starts paused until a worker RUNNING acknowledgement. No packet is
        // played merely because opening the device succeeded.
        std::cout << "audio_sink enabled=1 opened=" << bool(sound)
                  << " device_id=" << sound << " device_name=unavailable(default-selection)"
                  << " device_selection=default driver="
                  << (SDL_GetCurrentAudioDriver() ? SDL_GetCurrentAudioDriver() : "unavailable")
                  << " rate=" << audio_spec.freq << " channels=" << unsigned(audio_spec.channels)
                  << " format=" << audio_spec.format << " period_frames=" << audio_spec.samples
                  << " device_names=" << SDL_GetNumAudioDevices(0)
                  << " queue_cap_frames=" << lt::AudioQueue::cap_frames
                  << " physical_audibility=unobserved underruns=unavailable" << std::endl;
        if (!audio_failure.empty())
            std::cerr << "audio device failed: " << audio_failure << "; requesting ordinary Stop\n";
    }
    std::vector<uint8_t> pixels;
    lt_frame_info frame{sizeof(frame), 1, 0, 0, 0, 0, 0, 0, 0};
    uint64_t sequence = 0, start = now_ns();
    bool stopping = false, paused = false, terminal = false;
    uint64_t stop_since = 0;
    uint64_t pcm_received = 0, pcm_nonzero_samples = 0, pcm_loud_samples = 0, pcm_socket_dropped = 0,
             pcm_adapter_discarded = 0;
    lt::AudioQueue sink;
    uint64_t audio_command = 0;
    auto sink_bytes = [&] { return sound ? SDL_GetQueuedAudioSize(sound) : 0u; };
    auto sink_pause = [&](bool pause) {
        if (sound)
            SDL_PauseAudioDevice(sound, pause ? 1 : 0);
    };
    auto sink_clear = [&] {
        if (sound)
            SDL_ClearQueuedAudio(sound);
    };
    uint32_t pcm_peak_abs = 0;
    lt::ContactOwnership ownership;
    lt::WindowControls controls;
    auto &contacts = ownership.contacts;
    auto &fingers = ownership.fingers;
    uint32_t next_finger = 10000, display_rotation = 0;
    auto effective_rotation = [&](uint32_t w, uint32_t h) -> uint32_t {
        return (display_rotation + (w > h ? 90u : 0u)) % 360u;
    };
    auto script = script_file(o.script);
    size_t next_script = 0;
    lt::ControlDelivery delivery;
    auto mutates_guest = [](uint32_t kind) {
        return kind == Touch || kind == Button || kind == Motion || kind == Pause || kind == GuestRequest;
    };
    auto submit = [&](Packet p) {
        if ((stopping || interrupt_requested) && mutates_guest(p.kind))
            return false;
        if (p.kind == Touch)
            p.touch.timestamp_ns = now_ns();
        if (p.kind == Motion)
            p.motion.timestamp_ns = now_ns();
        if (p.kind == Pause) {
            p.audio_command = ++audio_command;
            sink.request(audio_command, sink_bytes, sink_pause, sink_clear);
            paused = p.value != 0;
        }
        auto kind = p.kind == Touch || p.kind == Button || p.kind == Motion ? lt::ControlDelivery::Kind::input
                    : p.kind == Cancel                                      ? lt::ControlDelivery::Kind::cancel
                    : p.kind == Pause                                       ? lt::ControlDelivery::Kind::pause
                                                                            : lt::ControlDelivery::Kind::lifecycle;
        bool sent = delivery.send(kind, [&] { return send_packet(sockets[0], p); });
        if (sent && p.kind == Touch)
            ownership.admitted(p.touch);
        if (delivery.needs_cancel() || p.kind == Cancel || p.kind == Pause || p.kind == Stop) {
            ownership.clear();
            controls.clear();
            const auto dropped = lt::discard_replay(script, next_script);
            if (o.trace_io)
                std::cout << "trace_replay_cancel observed_monotonic_ns=" << now_ns() << " pending_dropped=" << dropped
                          << std::endl;
        }
        if (!sent)
            std::cerr << "control backpressure: command " << p.kind << " rejected\n";
        return sent;
    };
    auto hardware_edge = [&](int button, bool down) {
        Packet p;
        p.kind = Button;
        p.button = uint32_t(button);
        p.value = down;
        return submit(p);
    };
    bool screenshot_written = false;
    uint64_t diagnostics_monotonic_ns = 0;
    lt_runtime_diagnostics diagnostics{sizeof(lt_runtime_diagnostics), 1, 0, 0, -1, 0, 0, 0, 0, 0};
    auto capture = [&](const std::string &path) {
        const uint64_t copy_started = now_ns();
        std::vector<uint8_t> capture_pixels;
        lt_frame_info captured{};
        uint64_t generation = 0;
        const auto read = lt::screenshot_read(shared, capture_pixels, captured, generation);
        require(read != lt::ScreenshotRead::invalid, "invalid coherent screenshot frame bounds");
        if (read != lt::ScreenshotRead::copied) {
            std::cout << "screenshot_retry observed_monotonic_ns=" << now_ns()
                      << " reason=no_coherent_current_copy path=" << path << std::endl;
            return;
        }
        const uint64_t copy_finished = now_ns();
        lt_error error{sizeof(error), 1, 0, {}};
        check(lt_frame_write_bmp(&captured, capture_pixels.data(), capture_pixels.size(), path.c_str(), &error), error);
        if (path == o.screenshot)
            screenshot_written = true;
        std::cout << "screenshot sequence=" << captured.sequence << " observed_monotonic_ns=" << now_ns()
                  << " frame_monotonic_ns=" << captured.timestamp_ns
                  << " coherent_readback=1 shared_generation=" << generation
                  << " copy_started_monotonic_ns=" << copy_started << " copy_finished_monotonic_ns=" << copy_finished
                  << " diagnostics_monotonic_ns=" << diagnostics_monotonic_ns
                  << " sleeping=" << diagnostics.display_sleeping << " backlight=" << diagnostics.backlight_level
                  << " agent=" << diagnostics.agent_status << " path=" << path << std::endl;
    };
    struct CaptureOnExit {
        std::function<void()> function;
        ~CaptureOnExit() { function(); }
    } capture_on_exit{[&] {
        if (!o.screenshot.empty() && !screenshot_written && frame.sequence) {
            try {
                capture(o.screenshot);
            } catch (const std::exception &e) {
                std::cerr << "failure screenshot unavailable: " << e.what() << "\n";
            }
        }
    }};
    auto stop = [&] {
        if (!stopping) {
            sink.stopped = true;
            sink.mute(sink_bytes, sink_pause, sink_clear);
            if (!o.screenshot.empty() && frame.sequence) {
                try {
                    capture(o.screenshot);
                } catch (const std::exception &e) {
                    std::cerr << "screenshot checkpoint failed: " << e.what() << "\n";
                }
            }
            Packet p;
            p.kind = Stop;
            require(submit(p), "shutdown command was not delivered; worker state remains dirty");
            stopping = true;
            stop_since = now_ns();
        }
    };
    auto cancel_controls = [&] {
        Packet p;
        p.kind = Cancel;
        submit(p);
        ownership.clear();
        controls.clear();
    };
    auto activate_control = [&](lt::WindowAction action) {
        if (stopping)
            return;
        if (action == lt::WindowAction::pause) {
            Packet p;
            p.kind = Pause;
            p.value = !paused;
            submit(p);
        } else if (action == lt::WindowAction::rotate) {
            cancel_controls();
            display_rotation = (display_rotation + 90) % 360;
        } else if (action == lt::WindowAction::screenshot) {
            const std::string path = o.screenshot.empty()
                ? o.state + "/screenshot-" + std::to_string(frame.sequence) + ".bmp" : o.screenshot;
            try {
                capture(path);
            } catch (const std::exception &e) {
                std::cerr << "live host screenshot failed: " << e.what() << "\n";
            }
        } else if (action == lt::WindowAction::stop)
            stop();
    };
    std::array<int, 5> controls_viewport{};
    if (admission_cancelled || interrupt_requested)
        stop();
    if (!audio_failure.empty())
        sink.fault(stop);
    auto touch = [&](uint32_t id, uint32_t phase, double x, double y) {
        Packet p;
        p.kind = Touch;
        p.touch = {sizeof(p.touch), 1, now_ns(), 1, 0, {}};
        p.touch.contacts[0] = {sizeof(lt_contact), 1, id, phase, x, y};
        return submit(p);
    };
    while (!terminal) {
        delivery.retry_cancel([&] {
            Packet cancel;
            cancel.kind = Cancel;
            return send_packet(sockets[0], cancel);
        });
        uint64_t now = now_ns();
        double elapsed = double(now - start) / 1e9;
        if (interrupt_requested || (o.seconds > 0 && elapsed >= o.seconds))
            stop();
        lt::dispatch_due_script(
            script, next_script, elapsed, [&] { return interrupt_requested != 0; }, stop,
            [&](const Script &command) {
                const bool admit = !stopping || !mutates_guest(command.packet.kind);
                if (!admit && o.trace_io)
                    std::cout << "trace_script_suppressed observed_monotonic_ns=" << now_ns()
                              << " kind=" << command.packet.kind << " reason=stopping" << std::endl;
                return admit;
            },
            [&](const Script &command) {
                if (command.packet.kind == Stop)
                    stop();
                else if (command.packet.kind == Screenshot) {
                    try {
                        capture(command.packet.guest_argument);
                    } catch (const std::exception &e) {
                        std::cerr << "checkpoint screenshot failed: " << e.what() << "\n";
                    }
                } else {
                    submit(command.packet);
                }
            });
        Packet update;
        while (receive(sockets[0], update)) {
            if (update.kind == Status) {
                const auto &s = update.status;
                final_receipt.latest = s;
                final_receipt.status_available = true;
                if (update.audio_command == audio_command && (s.state == LT_PAUSED || s.state == LT_RUNNING))
                    paused = update.pause_target || s.state == LT_PAUSED;
                sink.acknowledge(update.audio_command, update.audio_epoch,
                                 o.audio && sound && update.audio_running != 0, sink_pause);
                if (s.state != LT_RUNNING) {
                    sink.mute(sink_bytes, sink_pause, sink_clear);
                    if (s.state == LT_STOPPING || s.state == LT_STOPPED || s.state == LT_FAILED)
                        sink.stopped = true;
                }
                sink.observe(sink_bytes());
                diagnostics = update.diagnostics;
                diagnostics_monotonic_ns = update.diagnostics_monotonic_ns;
                pcm_socket_dropped = update.pcm_socket_dropped;
                std::cout << "status observed_monotonic_ns=" << now_ns() << " state=" << s.state
                          << " confirmed=" << s.guest_shutdown_confirmed << " dirty=" << s.dirty
                          << " frames=" << s.frames << " sleeping=" << diagnostics.display_sleeping
                          << " backlight=" << diagnostics.backlight_level << " agent=" << diagnostics.agent_status
                          << " shutdown_phase=" << diagnostics.shutdown_phase
                          << " shutdown_route=" << diagnostics.shutdown_route
                          << " shutdown_reply=" << diagnostics.shutdown_reply_received << ":"
                          << diagnostics.shutdown_reply_status << " frame_sequence=" << update.io.frame_sequence
                          << " frame_monotonic_ns=" << update.io.frame_timestamp_ns
                          << " pcm_captured=" << update.io.pcm_captured_frames
                          << " pcm_pulled=" << update.io.pcm_pulled_frames
                          << " pcm_native_dropped=" << update.io.pcm_dropped_frames
                          << " pcm_native_packets=" << update.io.pcm_queued_packets << " pcm_received=" << pcm_received
                          << " pcm_nonzero_samples=" << pcm_nonzero_samples << " pcm_loud_samples=" << pcm_loud_samples
                          << " pcm_peak_abs=" << pcm_peak_abs << " pcm_socket_dropped=" << pcm_socket_dropped
                          << " pcm_worker_discarded=" << update.pcm_worker_discarded
                          << " pcm_sdl_queued=" << sink.queued << " pcm_sdl_discarded=" << sink.discarded
                          << " pcm_adapter_discarded=" << pcm_adapter_discarded << " pcm_sdl_errors=" << sink.errors
                          << " pcm_sdl_depth=" << sink.depth << " pcm_sdl_peak_depth_bound=" << sink.peak_depth
                          << " pcm_sdl_consumed_estimate=" << sink.consumed_estimate
                          << " pcm_sink_muted=" << sink.muted << " pcm_sink_failed=" << sink.failed
                          << " pcm_sink_enabled=" << o.audio
                          << " pcm_epoch=" << update.audio_epoch << " pcm_command=" << update.audio_command
                          << " pcm_underruns=unavailable pcm_physical_audibility=unobserved" << std::endl;
                if (window) {
                    std::string title = "LightTouch - " + std::string(s.state == LT_RUNNING    ? "running"
                                                                      : s.state == LT_PAUSED   ? "paused"
                                                                      : s.state == LT_STOPPING ? "stopping"
                                                                      : s.state == LT_STARTING ? "starting"
                                                                                               : "stopped");
                    set_window_title(title);
                }
                if (s.state == LT_STOPPED || s.state == LT_FAILED) {
                    terminal = true;
                    break;
                }
            } else if (update.kind == Reply) {
                std::cerr << "command failed: " << update.error.message << "\n";
                ownership.clear();
                controls.clear();
                if (update.reserved == Pause) {
                    audio_failure = update.error.message;
                    sink.fault(stop);
                }
                lt::discard_replay(script, next_script);
                Packet cancel;
                cancel.kind = Cancel;
                // Cancellation can be rejected before the engine becomes ready.
                // Do not create an endless Reply/Cancel loop during startup.
                if (update.reserved != Cancel)
                    submit(cancel);
            } else if (update.kind == GuestResult) {
                const auto &result = update.guest_result;
                std::cout << "guest request=" << result.request_id << " state=" << result.state
                          << " status=" << result.guest_status << " bytes=" << result.bytes << " output="
                          << std::string(result.output, std::min<size_t>(result.bytes, sizeof(result.output))) << "\n";
                if (update.error.code)
                    std::cerr << "guest operation error: " << update.error.message << "\n";
            } else if (update.kind == InputStatus) {
                std::cout << "input batch=" << update.input_status.request_id << " state=" << update.input_status.state
                          << " engine_result=" << update.input_status.engine_result << "\n";
                if (update.input_status.state == 3) {
                    ownership.clear();
                    controls.clear();
                    lt::discard_replay(script, next_script);
                    std::cerr << update.error.message << "\n";
                }
            }
        }
        AudioPacket pcm;
        for (int budget = 0; budget < 16; budget++) {
            ssize_t n = recv(audio[0], &pcm, sizeof pcm, MSG_DONTWAIT);
            if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))
                break;
            if (n == 0)
                break;
            require(n == sizeof pcm && pcm.size == sizeof pcm && pcm.version == 1 &&
                        pcm.info.size == sizeof(lt_pcm_info) && pcm.info.version == 1 && pcm.info.frames <= 4096 &&
                        pcm.info.channels == 2 && pcm.info.sample_rate == lt::AudioQueue::rate,
                    "invalid PCM packet");
            pcm_received += pcm.info.frames;
            uint32_t packet_nonzero = 0, packet_first = 0, packet_last = 0;
            for (uint32_t i = 0; i < pcm.info.frames * 2; i++) {
                pcm_nonzero_samples += pcm.samples[i] != 0;
                if (pcm.samples[i]) {
                    if (!packet_nonzero)
                        packet_first = i;
                    packet_last = i;
                    packet_nonzero++;
                }
                uint32_t magnitude = uint32_t(std::abs(int(pcm.samples[i])));
                pcm_loud_samples += magnitude > 1000;
                pcm_peak_abs = std::max(pcm_peak_abs, magnitude);
            }
            if (o.trace_io && packet_nonzero)
                std::cout << "trace_pcm observed_monotonic_ns=" << now_ns() << " frames=" << pcm.info.frames
                          << " transport_epoch=" << pcm.epoch << " sink_epoch=" << sink.epoch
                          << " sink_muted=" << sink.muted
                          << " capture_relative_ns=" << pcm.info.timestamp_ns << " nonzero_samples=" << packet_nonzero
                          << " first_nonzero_sample=" << packet_first << " last_nonzero_sample=" << packet_last
                          << " sample_rate=" << pcm.info.sample_rate << " channels=" << pcm.info.channels << std::endl;
            if (sound) {
                bool failed = false;
                uint32_t accepted = sink.append(pcm.epoch, pcm.info.frames, sink_bytes(), [&](uint32_t frames) {
                    failed = SDL_QueueAudio(sound, pcm.samples.data(), frames * 4) != 0;
                    return !failed;
                });
                pcm_adapter_discarded += pcm.info.frames - accepted;
                if (failed) {
                    audio_failure = SDL_GetError();
                    std::cerr << "SDL audio queue failed: " << audio_failure << "; requesting ordinary Stop\n";
                    sink.fault(stop);
                }
            } else
                pcm_adapter_discarded += pcm.info.frames;
        }
        if (frame_copy(shared, pixels, frame, sequence) && renderer) {
            if (o.trace_io)
                std::cout << "trace_frame observed_monotonic_ns=" << now_ns() << " sequence=" << frame.sequence
                          << " source_monotonic_ns=" << frame.timestamp_ns << std::endl;
            if (!texture) {
                texture = lt::opaque_texture(renderer, int(frame.width), int(frame.height));
                require(texture, SDL_GetError());
            } else {
                int width = 0, height = 0;
                require(SDL_QueryTexture(texture, nullptr, nullptr, &width, &height) == 0,
                        std::string("SDL texture query: ") + SDL_GetError());
                if (width != int(frame.width) || height != int(frame.height)) {
                    SDL_DestroyTexture(texture);
                    texture = lt::opaque_texture(renderer, int(frame.width), int(frame.height));
                    require(texture, SDL_GetError());
                }
            }
            require(SDL_UpdateTexture(texture, nullptr, pixels.data(), int(frame.stride)) == 0,
                    std::string("SDL texture update: ") + SDL_GetError());
        }
        if (renderer) {
            int width = 0, height = 0;
            require(SDL_GetRendererOutputSize(renderer, &width, &height) == 0,
                    std::string("SDL renderer output: ") + SDL_GetError());
            int logical_width = 0, logical_height = 0;
            SDL_GetWindowSize(window, &logical_width, &logical_height);
            require(logical_width > 0 && logical_height > 0, "invalid window geometry");
            require(SDL_RenderSetScale(renderer, float(width) / logical_width, float(height) / logical_height) == 0,
                    std::string("SDL renderer scale: ") + SDL_GetError());
            const lt::ControlBarLayout layout{logical_width, logical_height};
            const uint32_t render_rotation = effective_rotation(frame.width, frame.height);
            const auto viewport = layout.guest(frame.width, frame.height, render_rotation);
            SDL_Rect dest{int((logical_width - frame.width * viewport.scale) / 2),
                          int((layout.top() - frame.height * viewport.scale) / 2),
                          int(frame.width * viewport.scale), int(frame.height * viewport.scale)};
            require(SDL_SetRenderDrawColor(renderer, 24, 24, 24, 255) == 0,
                    std::string("SDL clear color: ") + SDL_GetError());
            require(SDL_RenderClear(renderer) == 0, std::string("SDL clear: ") + SDL_GetError());
            require(!texture || SDL_RenderCopyEx(renderer, texture, nullptr, &dest, render_rotation, nullptr, SDL_FLIP_NONE) == 0,
                    std::string("SDL rotated frame: ") + SDL_GetError());
            lt::draw_control_bar(renderer, layout, controls, paused, stopping);
            SDL_RenderPresent(renderer);
        }
        SDL_Event event;
        while (SDL_PollEvent(&event)) {
            lt::desktop_cursor_event(window, event);
            if (window) {
                int w = 0, h = 0;
                SDL_GetWindowSize(window, &w, &h);
                const int active_rotation = int(effective_rotation(frame.width, frame.height));
                const std::array<int, 5> geometry{w, h, int(frame.width), int(frame.height), active_rotation};
                if (geometry != controls_viewport && controls.any())
                    cancel_controls();
                controls_viewport = geometry;
                ownership.resized(w, h, int(frame.width), int(frame.height), active_rotation, [&] {
                    Packet p;
                    p.kind = Cancel;
                    submit(p);
                    if (o.trace_io)
                        std::cout << "trace_viewport_cancel observed_monotonic_ns=" << now_ns()
                                  << " width=" << w << " height=" << h << " reason=changed" << std::endl;
                });
            }
            if (window && (event.type == SDL_FINGERDOWN || event.type == SDL_FINGERMOTION ||
                           event.type == SDL_FINGERUP || event.type == SDL_MOUSEBUTTONDOWN ||
                           event.type == SDL_MOUSEBUTTONUP || event.type == SDL_MOUSEMOTION)) {
                const bool finger = event.type == SDL_FINGERDOWN || event.type == SDL_FINGERMOTION ||
                                    event.type == SDL_FINGERUP;
                const bool motion = event.type == SDL_FINGERMOTION || event.type == SDL_MOUSEMOTION;
                const bool down = event.type == SDL_FINGERDOWN || event.type == SDL_MOUSEBUTTONDOWN;
                const bool up = event.type == SDL_FINGERUP || event.type == SDL_MOUSEBUTTONUP;
                if ((finger && event.tfinger.touchId == SDL_MOUSE_TOUCHID) ||
                    (!finger && (motion ? event.motion.which : event.button.which) == SDL_TOUCH_MOUSEID))
                    continue;
                int w = 0, h = 0;
                SDL_GetWindowSize(window, &w, &h);
                const double px = finger ? event.tfinger.x * w : motion ? event.motion.x : event.button.x;
                const double py = finger ? event.tfinger.y * h : motion ? event.motion.y : event.button.y;
                const lt::ControlBarLayout layout{w, h};
                const auto action = layout.hit(px, py);
                if (!finger && motion) {
                    bool consumed = false;
                    for (int button : {SDL_BUTTON_LEFT, SDL_BUTTON_RIGHT}) {
                        const lt::WindowControls::Owner owner{0, button};
                        if (controls.owns(owner)) {
                            consumed = true;
                            if (!controls.matches(owner, action))
                                controls.leave(owner, hardware_edge);
                        }
                    }
                    if (consumed && !contacts.count(1) && !contacts.count(2))
                        continue;
                } else {
                    const lt::WindowControls::Owner owner{finger ? 1 : 0,
                        finger ? event.tfinger.fingerId : int64_t(event.button.button)};
                    if (controls.owns(owner)) {
                        if (up)
                            controls.release(owner, action, hardware_edge, activate_control);
                        else if (motion && !controls.matches(owner, action))
                            controls.leave(owner, hardware_edge);
                        continue;
                    }
                    if (down && action != lt::WindowAction::none) {
                        if (!stopping && (finger || event.button.button == SDL_BUTTON_LEFT))
                            controls.press(owner, action, hardware_edge);
                        continue;
                    }
                }
            }
            if (event.type == SDL_QUIT)
                stop();
            else if (event.type == SDL_WINDOWEVENT && event.window.event == SDL_WINDOWEVENT_FOCUS_LOST) {
                cancel_controls();
            } else if (event.type == SDL_KEYDOWN || event.type == SDL_KEYUP) {
                bool down = event.type == SDL_KEYDOWN;
                if (event.key.repeat)
                    continue;
                auto key = event.key.keysym.sym;
                const auto action = lt::desktop_shortcut(key);
                if (action == lt::WindowAction::cancel) {
                    if (down)
                        cancel_controls();
                } else if (action != lt::WindowAction::none) {
                    if (lt::WindowControls::button(action) >= 0) {
                        const lt::WindowControls::Owner owner{2, key};
                        if (down)
                            controls.press(owner, action, hardware_edge);
                        else
                            controls.release(owner, action, hardware_edge, activate_control);
                    } else if (down)
                        activate_control(action);
                } else if ((key == SDLK_F5 || key == SDLK_F6) && down) {
                    std::cerr << "deterministic touch replay (guest acceptance requires observation)\n";
                    for (int step = 0; step <= 12; step++) {
                        Packet p;
                        p.kind = Touch;
                        p.touch = {sizeof(p.touch), 1, 0, 2, 0, {}};
                        uint32_t phase = step == 0 ? 0 : step == 12 ? 2 : 1;
                        double delta = key == SDLK_F5 ? .28 - step * .015 : .1 + step * .015;
                        p.touch.contacts[0] = {sizeof(lt_contact), 1, 101, phase, .5 - delta, .5};
                        p.touch.contacts[1] = {sizeof(lt_contact), 1, 102, phase, .5 + delta, .5};
                        script.push_back({elapsed + step * .08, p, true});
                    }
                    std::sort(script.begin() + next_script, script.end(),
                              [](const Script &a, const Script &b) { return a.at < b.at; });
                } else if (key == SDLK_F7 && down) {
                    std::cerr << "crossing/independent-lift replay (guest acceptance requires observation)\n";
                    for (int step = 0; step <= 16; step++) {
                        Packet p;
                        p.kind = Touch;
                        p.touch = {sizeof(p.touch), 1, 0, step <= 13 ? 2u : 1u, 0, {}};
                        if (step <= 12) {
                            const double offset = .46 * step / 12;
                            const uint32_t phase = step == 0 ? 0 : 1;
                            p.touch.contacts[0] = {sizeof(lt_contact), 1, 201, phase, .32 + offset, .46};
                            p.touch.contacts[1] = {sizeof(lt_contact), 1, 202, phase, .68 - offset, .54};
                        } else if (step == 13) {
                            p.touch.contacts[0] = {sizeof(lt_contact), 1, 201, 2, .78, .46};
                            p.touch.contacts[1] = {sizeof(lt_contact), 1, 202, 1, .22, .54};
                        } else {
                            p.touch.contacts[0] = {sizeof(lt_contact),      1,  202, step == 16 ? 2u : 1u,
                                                   .22 + .08 * (step - 13), .54};
                        }
                        script.push_back({elapsed + step * .08, p, true});
                    }
                    std::sort(script.begin() + next_script, script.end(),
                              [](const Script &a, const Script &b) { return a.at < b.at; });
                } else if (down && (key == SDLK_LEFT || key == SDLK_RIGHT || key == SDLK_UP || key == SDLK_DOWN)) {
                    Packet p;
                    p.kind = Motion;
                    p.motion = {sizeof(lt_motion), 1, now_ns(), 1, 0, {0, 9.80665, 0}, {0, 0, 0}};
                    if (key == SDLK_LEFT || key == SDLK_RIGHT)
                        p.motion.acceleration[0] = key == SDLK_LEFT ? -9.80665 : 9.80665;
                    else
                        p.motion.acceleration[1] = key == SDLK_UP ? 9.80665 : -9.80665;
                    submit(p);
                    std::cerr << "manual acceleration replay; not physical gyro\n";
                }
            } else if (frame.width &&
                       (event.type == SDL_FINGERDOWN || event.type == SDL_FINGERMOTION || event.type == SDL_FINGERUP)) {
                int width = 0, height = 0;
                SDL_GetWindowSize(window, &width, &height);
                const uint32_t touch_rotation = effective_rotation(frame.width, frame.height);
                const auto viewport = lt::ControlBarLayout{width, height}.guest(frame.width, frame.height, touch_rotation);
                double x = 0, y = 0;
                lt_status mapped = lt_map_contact(event.tfinger.x * width, event.tfinger.y * height,
                    viewport.left, viewport.top, viewport.width, viewport.height, touch_rotation, &x, &y);
                if (mapped != LT_OK && fingers.count(event.tfinger.fingerId)) {
                    ownership.outside(false, [&] {
                        Packet p;
                        p.kind = Cancel;
                        submit(p);
                    });
                    continue;
                }
                if (event.type == SDL_FINGERDOWN && mapped == LT_OK) {
                    uint32_t id = next_finger++;
                    fingers[event.tfinger.fingerId] = id;
                    contacts[id] = {x, y};
                    touch(id, 0, x, y);
                } else if (fingers.count(event.tfinger.fingerId)) {
                    uint32_t id = fingers[event.tfinger.fingerId];
                    if (event.type == SDL_FINGERUP) {
                        auto c = contacts[id];
                        touch(id, 2, c.first, c.second);
                        contacts.erase(id);
                        fingers.erase(event.tfinger.fingerId);
                    } else if (mapped == LT_OK) {
                        contacts[id] = {x, y};
                        touch(id, 1, x, y);
                    }
                }
            } else if (frame.width && (event.type == SDL_MOUSEBUTTONDOWN || event.type == SDL_MOUSEBUTTONUP ||
                                       event.type == SDL_MOUSEMOTION)) {
                if ((event.type == SDL_MOUSEMOTION && event.motion.which == SDL_TOUCH_MOUSEID) ||
                    (event.type != SDL_MOUSEMOTION && event.button.which == SDL_TOUCH_MOUSEID))
                    continue;
                int width = 0, height = 0;
                SDL_GetWindowSize(window, &width, &height);
                const uint32_t mouse_rotation = effective_rotation(frame.width, frame.height);
                const auto viewport = lt::ControlBarLayout{width, height}.guest(frame.width, frame.height, mouse_rotation);
                double x = 0, y = 0;
                int px = event.type == SDL_MOUSEMOTION ? event.motion.x : event.button.x,
                    py = event.type == SDL_MOUSEMOTION ? event.motion.y : event.button.y;
                lt_status mapped = lt_map_contact(px, py, viewport.left, viewport.top,
                    viewport.width, viewport.height, mouse_rotation, &x, &y);
                if ((contacts.count(1) || contacts.count(2)) && ownership.outside(mapped == LT_OK, [&] {
                        Packet p;
                        p.kind = Cancel;
                        submit(p);
                    }))
                    continue;
                if (event.type == SDL_MOUSEMOTION) {
                    // A failed send clears local ownership. Iterate a snapshot
                    // so cancellation cannot invalidate this traversal.
                    const auto held = contacts;
                    for (const auto &c : held) {
                        if (c.first != 1 && c.first != 2)
                            continue; // Physical mouse cannot move a finger's ID.
                        if (mapped == LT_OK) {
                            contacts[c.first] = {x, y};
                            if (!touch(c.first, 1, x, y))
                                break;
                        }
                    }
                } else {
                    if (event.button.button != SDL_BUTTON_LEFT && event.button.button != SDL_BUTTON_RIGHT)
                        continue;
                    uint32_t id = event.button.button == SDL_BUTTON_LEFT ? 1 : 2;
                    if (event.type == SDL_MOUSEBUTTONDOWN && mapped == LT_OK) {
                        contacts[id] = {x, y};
                        touch(id, 0, x, y);
                    } else if (event.type == SDL_MOUSEBUTTONUP && contacts.count(id)) {
                        auto c = contacts[id];
                        touch(id, 2, c.first, c.second);
                        contacts.erase(id);
                    }
                }
            }
        }
        if (stopping && lt::elapsed_exceeds(now_ns(), stop_since, lt::parent_shutdown_timeout_ns)) {
            throw std::runtime_error("shutdown timeout; worker terminated, dirty state preserved");
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    if (!o.screenshot.empty() && !screenshot_written)
        capture(o.screenshot);
    sdl.release();
    uint64_t exit_budget = 5000000000ull;
    const uint64_t exiting = now_ns();
    if (stopping && exiting >= stop_since) {
        const uint64_t elapsed_stop = exiting - stop_since;
        exit_budget = elapsed_stop >= lt::parent_shutdown_timeout_ns
                          ? 0
                          : std::min(exit_budget, lt::parent_shutdown_timeout_ns - elapsed_stop);
    }
    require(child.wait_bounded(exit_budget), "worker process exit deadline after terminal receipt; state retained");
    final_receipt.frontend_return = sink.failed ? 2 : WIFEXITED(child.status) ? WEXITSTATUS(child.status) : 2;
    return final_receipt.frontend_return;
}
int main(int argc, char **argv) {
    try {
        InterruptGuard import_and_library_interrupts;
        auto o = options(argc, argv);
        prepare_library(o);
        if (!o.worker && !o.library.empty() && (o.engine.empty() || !o.set_guest_package.empty()))
            return 0;
        return o.worker ? worker(o) : frontend(o, argc, argv);
    } catch (const std::exception &e) {
        std::cerr << "LightTouch: " << e.what() << "\n";
        return 1;
    }
}
