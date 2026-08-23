module;
#include "waywallen/app.moc.h"
#undef assert
#include <KWindowEffects>
#include <KWindowSystem>
#include <QDBusConnection>
#include <QDBusConnectionInterface>
#include <QCoreApplication>
#include <QAbstractItemModel>
#include <QDir>
#include <QElapsedTimer>
#include <QEvent>
#include <QImage>
#include <QImageWriter>
#include <QInputDevice>
#include <QPointingDevice>
#include <QQuickItem>
#include <QRegion>
#include <QScreen>
#include <QTimer>
#include <QVector>
#include <QWheelEvent>
#include <rstd/macro.hpp>
#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <memory>
#include <mutex>
#include <numeric>

module waywallen;
import :app;
import :display;
import :gpu;
import :renderer;
import :query;
import :notify;
import :ui_language;

using namespace waywallen;
using namespace Qt::Literals::StringLiterals;

namespace proto = waywallen::control::v1;

namespace
{

// This probe is deliberately only constructed when WAYWALLEN_SCROLL_TIMING is
// set.  All its callbacks run on the GUI thread, so it can safely observe the
// Flickable's QML state without crossing into the scene-graph render thread.
constexpr int    k_scroll_timing_quiet_ms { 220 };
// Keep diagnostics below the animator's 0.04 px settle threshold so the
// sub-pixel tail is counted instead of appearing as lost travel.
constexpr double k_scroll_timing_position_epsilon { 0.001 };

template<typename T>
auto sample_percentile(const QVector<T>& values, int percentage) -> double {
    if (values.isEmpty()) return 0.0;
    auto sorted = values;
    std::sort(sorted.begin(), sorted.end());
    const auto index = qMin(sorted.size() - 1, (sorted.size() * percentage + 99) / 100 - 1);
    return static_cast<double>(sorted.at(index));
}

template<typename T>
auto sample_maximum(const QVector<T>& values) -> double {
    if (values.isEmpty()) return 0.0;
    return static_cast<double>(*std::max_element(values.cbegin(), values.cend()));
}

auto find_visual_item(QQuickItem* item, const QString& object_name) -> QQuickItem* {
    if (! item) return nullptr;
    if (item->objectName() == object_name) return item;
    for (auto* child : item->childItems()) {
        if (auto* found = find_visual_item(child, object_name)) return found;
    }
    return nullptr;
}

void collect_visual_items(QQuickItem* item, const QString& object_name,
                          QVector<QQuickItem*>& output) {
    if (! item) return;
    if (item->objectName() == object_name) output.push_back(item);
    for (auto* child : item->childItems())
        collect_visual_items(child, object_name, output);
}

struct ScrollTimingState {
    QElapsedTimer     clock;
    QPointer<QObject> grid;
    QString           grid_name;
    QPointer<QTimer>  settle_timer;
    QPointer<QTimer>  discovery_timer;
    QMetaObject::Connection content_connection;
    QMetaObject::Connection moving_connection;
    std::atomic_bool frame_sampling_active { false };
    std::mutex       frame_mutex;

    bool   active { false };
    bool   moving { false };
    bool   awaiting_input_response { false };
    qint64 started_ns { 0 };
    qint64 last_activity_ns { 0 };
    qint64 last_wheel_ns { 0 };
    qint64 last_content_change_ns { 0 };
    double last_content_y { 0.0 };
    double session_start_y { 0.0 };
    double last_tick_y { 0.0 };
    int    trajectory_direction { 0 };
    qint64 stale_tick_run { 0 };

    qint64          wheel_events { 0 };
    qint64          pixel_wheel_events { 0 };
    qint64          angle_wheel_events { 0 };
    qint64          touchpad_wheel_events { 0 };
    qint64          mouse_wheel_events { 0 };
    qint64          content_updates { 0 };
    qint64          gui_ticks { 0 };
    qint64          position_ticks { 0 };
    qint64          max_stale_tick_run { 0 };
    qint64          direction_reversals { 0 };
    qint64          frame_swaps { 0 };
    double          reversed_distance_px { 0.0 };
    double          total_distance_px { 0.0 };
    QVector<qint64> input_to_content_ns;
    QVector<qint64> content_intervals_ns;
    QVector<double> content_steps_px;
    QVector<qint64> frame_timestamps_ns;

    ScrollTimingState() { clock.start(); }

    auto now() const -> qint64 { return clock.nsecsElapsed(); }

    auto contentY() const -> double { return grid ? grid->property("contentY").toDouble() : 0.0; }

    static auto signOf(double value) -> int {
        if (value > k_scroll_timing_position_epsilon) return 1;
        if (value < -k_scroll_timing_position_epsilon) return -1;
        return 0;
    }

    void resetSession(qint64 timestamp) {
        frame_sampling_active.store(false, std::memory_order_release);
        active                  = true;
        awaiting_input_response = false;
        started_ns              = timestamp;
        last_activity_ns        = timestamp;
        last_wheel_ns           = 0;
        last_content_change_ns  = 0;
        trajectory_direction    = 0;
        stale_tick_run          = 0;
        wheel_events            = 0;
        pixel_wheel_events      = 0;
        angle_wheel_events      = 0;
        touchpad_wheel_events   = 0;
        mouse_wheel_events      = 0;
        content_updates         = 0;
        gui_ticks               = 0;
        position_ticks          = 0;
        max_stale_tick_run      = 0;
        direction_reversals     = 0;
        reversed_distance_px    = 0.0;
        total_distance_px       = 0.0;
        input_to_content_ns.clear();
        content_intervals_ns.clear();
        content_steps_px.clear();
        {
            const std::scoped_lock lock(frame_mutex);
            frame_timestamps_ns.clear();
            frame_swaps = 0;
        }
        frame_sampling_active.store(true, std::memory_order_release);

        last_content_y = contentY();
        session_start_y = last_content_y;
        last_tick_y    = last_content_y;
    }

    void beginSession(qint64 timestamp) {
        if (! active) resetSession(timestamp);
    }

    void armSettleTimer() {
        if (settle_timer) settle_timer->start(k_scroll_timing_quiet_ms);
    }

    void onWheel(const QWheelEvent& event) {
        const auto timestamp = now();
        beginSession(timestamp);

        last_wheel_ns = timestamp;
        ++wheel_events;
        if (event.pixelDelta().y() != 0) ++pixel_wheel_events;
        if (event.angleDelta().y() != 0) ++angle_wheel_events;
        if (const auto* device = event.pointingDevice()) {
            if (device->type() == QInputDevice::DeviceType::TouchPad)
                ++touchpad_wheel_events;
            else if (device->type() == QInputDevice::DeviceType::Mouse)
                ++mouse_wheel_events;
        }

        awaiting_input_response = true;
        last_activity_ns        = timestamp;
        armSettleTimer();
    }

    void onContentYChanged() {
        if (! grid) return;
        const auto timestamp = now();
        const auto y         = contentY();

        // A direct wheel step can begin and end movement between two Qt
        // property notifications.  The event filter starts those sessions;
        // programmatic layout changes do not create a diagnostic session.
        if (! active) {
            if (! grid->property("moving").toBool()) return;
            beginSession(timestamp);
        }

        const auto delta = y - last_content_y;
        last_content_y = y;
        if (std::abs(delta) <= k_scroll_timing_position_epsilon) return;

        if (awaiting_input_response && last_wheel_ns > 0) {
            input_to_content_ns.push_back(timestamp - last_wheel_ns);
            awaiting_input_response = false;
        }
        if (last_content_change_ns > 0)
            content_intervals_ns.push_back(timestamp - last_content_change_ns);
        last_content_change_ns = timestamp;
        content_steps_px.push_back(std::abs(delta));
        total_distance_px += std::abs(delta);
        ++content_updates;

        const auto direction = signOf(delta);
        if (trajectory_direction == 0)
            trajectory_direction = direction;
        else if (direction != 0 && direction != trajectory_direction) {
            ++direction_reversals;
            reversed_distance_px += std::abs(delta);
        }

        last_activity_ns = timestamp;
        armSettleTimer();
    }

    void onMovementChanged() {
        if (! grid) return;
        moving               = grid->property("moving").toBool();
        const auto timestamp = now();
        if (moving) {
            beginSession(timestamp);
            last_activity_ns = timestamp;
            if (settle_timer) settle_timer->stop();
        } else if (active) {
            last_activity_ns = timestamp;
            armSettleTimer();
        }
    }

    void onAfterAnimating() {
        if (! active || ! grid) return;
        const auto y = contentY();
        ++gui_ticks;

        if (std::abs(y - last_tick_y) <= k_scroll_timing_position_epsilon) {
            ++stale_tick_run;
            max_stale_tick_run = std::max(max_stale_tick_run, stale_tick_run);
        } else {
            ++position_ticks;
            stale_tick_run = 0;
        }
        last_tick_y = y;
    }

    void onFrameSwapped() {
        if (! frame_sampling_active.load(std::memory_order_acquire)) return;
        const auto timestamp = now();
        const std::scoped_lock lock(frame_mutex);
        if (! frame_sampling_active.load(std::memory_order_relaxed)) return;
        frame_timestamps_ns.push_back(timestamp);
        ++frame_swaps;
    }

    void finishIfQuiet() {
        if (! active) return;
        const auto timestamp = now();
        const auto quiet_ns  = qint64(k_scroll_timing_quiet_ms) * 1'000'000;
        if (moving || timestamp - last_activity_ns < quiet_ns) {
            armSettleTimer();
            return;
        }

        const auto active_elapsed_ns = std::max<qint64>(0, last_activity_ns - started_ns);
        const auto elapsed_ms        = active_elapsed_ns / 1'000'000.0;
        const auto rate              = [active_elapsed_ns](qint64 count) {
            return active_elapsed_ns > 0
                ? count * 1'000'000'000.0 / active_elapsed_ns
                : 0.0;
        };
        const auto fresh_percent = gui_ticks > 0 ? position_ticks * 100.0 / gui_ticks : 0.0;
        frame_sampling_active.store(false, std::memory_order_release);
        QVector<qint64> frame_timestamp_sample;
        QVector<qint64> frame_interval_sample;
        {
            const std::scoped_lock lock(frame_mutex);
            frame_timestamp_sample = frame_timestamps_ns;
        }
        qint64 frame_swap_sample { 0 };
        qint64 previous_frame_timestamp { 0 };
        for (const auto frame_timestamp : frame_timestamp_sample) {
            if (frame_timestamp < started_ns || frame_timestamp > last_activity_ns)
                continue;
            if (previous_frame_timestamp > 0)
                frame_interval_sample.push_back(frame_timestamp
                                                - previous_frame_timestamp);
            previous_frame_timestamp = frame_timestamp;
            ++frame_swap_sample;
        }
        std::fprintf(stderr,
                     "waywallen scroll timing: grid=%s duration_ms=%.1f wheel_events=%lld "
                     "wheel_hz=%.1f pixel_wheel=%lld angle_wheel=%lld "
                     "touchpad=%lld mouse=%lld input_to_content_p95_ms=%.3f "
                     "content_updates=%lld content_hz=%.1f "
                     "content_dt_ms[p50=%.3f p95=%.3f max=%.3f] "
                     "content_step_px[p95=%.3f max=%.3f] gui_ticks=%lld "
                     "gui_tick_hz=%.1f position_ticks=%lld fresh_gui_ticks_pct=%.1f "
                     "frame_swaps=%lld frame_hz=%.1f frame_dt_p95_ms=%.3f "
                     "max_stale_gui_ticks=%lld direction_reversals=%lld "
                     "reversed_px=%.3f start_y=%.3f end_y=%.3f "
                     "net_distance_px=%.3f total_distance_px=%.3f\n",
                     qPrintable(grid_name), elapsed_ms,
                     static_cast<long long>(wheel_events),
                     rate(wheel_events),
                     static_cast<long long>(pixel_wheel_events),
                     static_cast<long long>(angle_wheel_events),
                     static_cast<long long>(touchpad_wheel_events),
                     static_cast<long long>(mouse_wheel_events),
                     sample_percentile(input_to_content_ns, 95) / 1'000'000.0,
                     static_cast<long long>(content_updates),
                     rate(content_updates),
                     sample_percentile(content_intervals_ns, 50) / 1'000'000.0,
                     sample_percentile(content_intervals_ns, 95) / 1'000'000.0,
                     sample_maximum(content_intervals_ns) / 1'000'000.0,
                     sample_percentile(content_steps_px, 95),
                     sample_maximum(content_steps_px),
                     static_cast<long long>(gui_ticks),
                     rate(gui_ticks),
                     static_cast<long long>(position_ticks),
                     fresh_percent,
                     static_cast<long long>(frame_swap_sample),
                     rate(frame_swap_sample),
                     sample_percentile(frame_interval_sample, 95) / 1'000'000.0,
                     static_cast<long long>(max_stale_tick_run),
                     static_cast<long long>(direction_reversals),
                     reversed_distance_px, session_start_y, contentY(),
                     contentY() - session_start_y, total_distance_px);
        std::fflush(stderr);
        active                  = false;
        awaiting_input_response = false;
    }
};

} // namespace

auto app_instance(waywallen::App* in = nullptr) -> waywallen::App* {
    static waywallen::App* instance { in };
    rstd_assert(instance != nullptr, "app object not inited");
    rstd_assert(in == nullptr || instance == in, "there should be only one app object");
    return instance;
}

class AppPrivate {
public:
    AppPrivate(App* self, quint16 port)
        : m_p(self),
          m_main_win(nullptr),
          m_qml_network_cache(1024ll * 1024ll * 1024ll),
          m_backend(Box<Backend>::make(port)),
          m_display_mgr(Box<DisplayManager>::make()),
          m_renderer_mgr(Box<RendererManager>::make()),
          m_library_mgr(Box<LibraryManager>::make()),
          m_gpu_mgr(Box<GpuManager>::make()),
          m_qml_engine(Box<QQmlApplicationEngine>::make()),
          m_ui_language(Box<UiLanguageController>::make(
              *qobject_cast<QGuiApplication*>(QGuiApplication::instance()), *m_qml_engine)),
          m_port(port) {}
    ~AppPrivate() { save_settings(); }

    void save_settings() {}

    App*                   m_p;
    QPointer<QQuickWindow> m_main_win;
    QmlNetworkDiskCache    m_qml_network_cache;
    // Reverse dependency order keeps the QML engine first and Backend last during destruction.
    Box<Backend>               m_backend;
    Box<DisplayManager>        m_display_mgr;
    Box<RendererManager>       m_renderer_mgr;
    Box<LibraryManager>        m_library_mgr;
    Box<GpuManager>            m_gpu_mgr;
    Box<QQmlApplicationEngine> m_qml_engine;
    Box<UiLanguageController>  m_ui_language;
    std::unique_ptr<ScrollTimingState> m_scroll_timing;
    qint64                     m_network_cache_size { 0 };
    bool                       m_frosted_glass_available { false };
    quint16                    m_port;
};

namespace waywallen
{

App* App::create(QQmlEngine*, QJSEngine*) {
    auto app = app_instance();
    // not delete by qml
    QJSEngine::setObjectOwnership(app, QJSEngine::CppOwnership);
    return app;
}

App* App::instance() { return app_instance(); }

App::App(quint16 port, rstd::empty): QObject(nullptr), d_ptr(new AppPrivate(this, port)) {
    app_instance(this);
    QGuiApplication::instance()->installEventFilter(this);
}

App::~App() {
    QGuiApplication::instance()->removeEventFilter(this);
    QAsyncResult::dropEx();
}

void App::init() {
    Q_D(App);
    auto engine = this->engine();
    d->m_qml_network_cache.install(*engine);
    refreshNetworkCacheSize();

    QAsyncResult::initEx(this, rstd::usize(4), [](QStringView error) {
        Q_EMIT App::instance()->errorOccurred(error.toString());
    });

    connect(
        engine, &QQmlApplicationEngine::quit, QGuiApplication::instance(), &QGuiApplication::quit);

    // Resolve ws port. Priority: explicit --ws-port override > DBus-discovered.
    auto* dbus = DaemonDBusClient::instance();
    if (d->m_port == 0 && dbus->status() == DaemonDBusClient::Connected) {
        quint16 p = dbus->wsPort();
        if (p != 0) {
            d->m_backend->setPort(p);
        }
    }

    // React to daemon availability / port changes. The backend is only
    // (re)configured when the daemon reports `Connected` — VersionMissing
    // and VersionMismatch hold the backend disconnected even if a port
    // value is in hand, since the wire contract isn't trusted.
    auto sync_backend = [this, d, dbus]() {
        if (d->m_port != 0) {
            // Explicit override from CLI; ignore DBus-driven changes.
            return;
        }
        if (dbus->status() != DaemonDBusClient::Connected) {
            d->m_backend->disconnect();
            return;
        }
        const quint16 port = dbus->wsPort();
        if (port == 0) {
            d->m_backend->disconnect();
            return;
        }
        d->m_backend->setPort(port);
        d->m_backend->connectTo();
    };
    connect(dbus, &DaemonDBusClient::wsPortChanged, this, sync_backend);
    connect(dbus, &DaemonDBusClient::statusChanged, this, sync_backend);

    d->m_display_mgr->attachTo(d->m_backend.get());
    d->m_renderer_mgr->attachTo(d->m_backend.get());
    d->m_library_mgr->attachTo(d->m_backend.get());

    // Perform full sync on every connection (initial and reconnect).
    connect(d->m_backend.get(), &Backend::connected, this, [d]() {
        qDebug("ws connected; triggering full status sync");
        // We use queries for the async fetch + manager sync side effects.
        // Queries are parented to the manager so they don't leak.
        auto* dq = new DisplayListQuery(d->m_display_mgr.get());
        dq->reload();
        auto* cq = new CanvasListQuery(d->m_display_mgr.get());
        cq->reload();
        auto* rq = new RendererListQuery(d->m_renderer_mgr.get());
        rq->reload();
        auto* lq = new LibraryListQuery(d->m_library_mgr.get());
        lq->reload();
        auto* gq = new GpuListQuery(d->m_gpu_mgr.get());
        gq->reload();
    });

    // Eagerly construct the daemon-event mirror. Without this Notify
    // would only spring into existence when the first QML consumer
    // accesses it — and would miss the daemon's startup scan event.
    (void)Notify::instance();

    // Connect to the daemon's WebSocket (no-op if port is still 0).
    d->m_backend->connectTo();

    // `isEffectAvailable()` is based on the legacy atom capability and can
    // return false on a Wayland KWin session even though KWin accepts the
    // modern blur request.  Detect the active KWin service as the Wayland
    // fallback, so QML can use translucent surfaces on the compositor that
    // actually owns the effect.
    const auto* session_dbus = QDBusConnection::sessionBus().interface();
    const bool wayland_kwin = KWindowSystem::isPlatformWayland() && session_dbus
        && session_dbus->isServiceRegistered(u"org.kde.KWin"_s).value();
    d->m_frosted_glass_available = KWindowEffects::isEffectAvailable(KWindowEffects::BlurBehind)
        || wayland_kwin;
    engine->addImportPath(u"qrc:/"_s);
    // Load the main window from the QML module.
    engine->loadFromModule("waywallen.ui", "Window");

    for (auto el : engine->rootObjects()) {
        if (auto win = qobject_cast<QQuickWindow*>(el)) {
            d->m_main_win = win;
        }
    }

    rstd_assert(d->m_main_win, "main window must exist");

    if (qEnvironmentVariableIsSet("WAYWALLEN_RESIZE_TIMING")) {
        struct ResizeTimingState {
            std::chrono::steady_clock::time_point started {
                std::chrono::steady_clock::now()
            };
            std::atomic<int> latest_sequence { 0 };
            std::atomic<int> latest_width { 0 };
            std::atomic<int> latest_height { 0 };
            std::atomic<qint64> latest_change_ns { 0 };
            std::atomic<int> synchronized_sequence { 0 };
            std::atomic<int> synchronized_width { 0 };
            std::atomic<int> synchronized_height { 0 };
            std::atomic<qint64> synchronized_ns { 0 };
            std::atomic<qint64> synchronized_after_ns { 0 };
            std::atomic<qint64> rendering_started_ns { 0 };
            std::atomic<qint64> rendering_finished_ns { 0 };
            std::atomic<int> reported_swap_sequence { 0 };
            std::atomic_bool session_active { false };
            std::mutex session_mutex;
            QVector<qint64> session_geometry_timestamps_ns;
            QVector<qint64> session_frame_timestamps_ns;
            QVector<qint64> session_geometry_to_swap_ns;
            QVector<qint64> session_sync_to_swap_ns;
            QVector<qint64> session_sync_ns;
            QVector<qint64> session_render_ns;
            int session_last_width { -1 };
            int session_last_height { -1 };

            auto elapsedNs() const -> qint64 {
                return std::chrono::duration_cast<std::chrono::nanoseconds>(
                    std::chrono::steady_clock::now() - started).count();
            }
        };
        auto resize_timing = std::make_shared<ResizeTimingState>();
        resize_timing->latest_width.store(d->m_main_win->width());
        resize_timing->latest_height.store(d->m_main_win->height());

        auto* resize_quiet_timer = new QTimer(d->m_main_win);
        resize_quiet_timer->setSingleShot(true);
        resize_quiet_timer->setInterval(250);
        QObject::connect(resize_quiet_timer, &QTimer::timeout, d->m_main_win,
                         [resize_timing, window = QPointer<QQuickWindow>(d->m_main_win)] {
            resize_timing->session_active.store(false, std::memory_order_release);
            QVector<qint64> geometry_timestamps;
            QVector<qint64> frame_timestamps;
            QVector<qint64> geometry_to_swap;
            QVector<qint64> sync_to_swap;
            QVector<qint64> sync;
            QVector<qint64> render;
            {
                const std::scoped_lock lock(resize_timing->session_mutex);
                geometry_timestamps = resize_timing->session_geometry_timestamps_ns;
                frame_timestamps = resize_timing->session_frame_timestamps_ns;
                geometry_to_swap = resize_timing->session_geometry_to_swap_ns;
                sync_to_swap = resize_timing->session_sync_to_swap_ns;
                sync = resize_timing->session_sync_ns;
                render = resize_timing->session_render_ns;
            }
            const auto sample_rate = [](const QVector<qint64>& timestamps) {
                if (timestamps.size() < 2) return 0.0;
                const auto duration = timestamps.constLast() - timestamps.constFirst();
                return duration > 0
                    ? (timestamps.size() - 1) * 1'000'000'000.0 / duration : 0.0;
            };
            const auto* screen = window ? window->screen() : nullptr;
            std::fprintf(stderr,
                         "waywallen resize session: geometry_updates=%lld geometry_hz=%.1f "
                         "swaps=%lld swap_hz=%.1f geometry_to_swap_p95_ms=%.3f "
                         "sync_to_swap_p95_ms=%.3f sync_p95_ms=%.3f render_p95_ms=%.3f "
                         "output=%s refresh_hz=%.3f\n",
                         static_cast<long long>(geometry_timestamps.size()),
                         sample_rate(geometry_timestamps),
                         static_cast<long long>(frame_timestamps.size()),
                         sample_rate(frame_timestamps),
                         sample_percentile(geometry_to_swap, 95) / 1'000'000.0,
                         sample_percentile(sync_to_swap, 95) / 1'000'000.0,
                         sample_percentile(sync, 95) / 1'000'000.0,
                         sample_percentile(render, 95) / 1'000'000.0,
                         screen ? qPrintable(screen->name()) : "unknown",
                         screen ? screen->refreshRate() : 0.0);
            std::fflush(stderr);
        });

        const auto record_geometry = [resize_timing, window =
                                          QPointer<QQuickWindow>(d->m_main_win),
                                      resize_quiet_timer] {
            if (! window) return;
            const auto now = resize_timing->elapsedNs();
            const auto sequence = resize_timing->latest_sequence.fetch_add(1) + 1;
            resize_timing->latest_width.store(window->width());
            resize_timing->latest_height.store(window->height());
            resize_timing->latest_change_ns.store(now);
            const bool new_geometry = window->width() != resize_timing->session_last_width
                || window->height() != resize_timing->session_last_height;
            if (new_geometry) {
                if (! resize_timing->session_active.load(std::memory_order_acquire)) {
                    const std::scoped_lock lock(resize_timing->session_mutex);
                    resize_timing->session_geometry_timestamps_ns.clear();
                    resize_timing->session_frame_timestamps_ns.clear();
                    resize_timing->session_geometry_to_swap_ns.clear();
                    resize_timing->session_sync_to_swap_ns.clear();
                    resize_timing->session_sync_ns.clear();
                    resize_timing->session_render_ns.clear();
                    resize_timing->session_active.store(true, std::memory_order_release);
                }
                {
                    const std::scoped_lock lock(resize_timing->session_mutex);
                    resize_timing->session_geometry_timestamps_ns.push_back(now);
                }
                resize_timing->session_last_width = window->width();
                resize_timing->session_last_height = window->height();
            }
            resize_quiet_timer->start();
            const auto* screen = window->screen();
            std::fprintf(stderr,
                         "waywallen resize configure: seq=%d t_ms=%.3f window=%dx%d "
                         "output=%s refresh_hz=%.3f\n",
                         sequence, now / 1'000'000.0, window->width(), window->height(),
                         screen ? qPrintable(screen->name()) : "unknown",
                         screen ? screen->refreshRate() : 0.0);
            std::fflush(stderr);
        };
        QObject::connect(d->m_main_win, &QWindow::widthChanged, d->m_main_win,
                         [record_geometry](int) { record_geometry(); });
        QObject::connect(d->m_main_win, &QWindow::heightChanged, d->m_main_win,
                         [record_geometry](int) { record_geometry(); });

        QObject::connect(d->m_main_win, &QQuickWindow::beforeSynchronizing,
                         d->m_main_win, [resize_timing] {
            const auto sequence = resize_timing->latest_sequence.load();
            if (sequence == resize_timing->synchronized_sequence.load()) return;
            resize_timing->synchronized_width.store(resize_timing->latest_width.load());
            resize_timing->synchronized_height.store(resize_timing->latest_height.load());
            resize_timing->synchronized_ns.store(resize_timing->elapsedNs());
            resize_timing->synchronized_sequence.store(sequence);
        }, Qt::DirectConnection);
        QObject::connect(d->m_main_win, &QQuickWindow::afterSynchronizing,
                         d->m_main_win, [resize_timing] {
            resize_timing->synchronized_after_ns.store(resize_timing->elapsedNs());
        }, Qt::DirectConnection);
        QObject::connect(d->m_main_win, &QQuickWindow::beforeRendering,
                         d->m_main_win, [resize_timing] {
            resize_timing->rendering_started_ns.store(resize_timing->elapsedNs());
        }, Qt::DirectConnection);
        QObject::connect(d->m_main_win, &QQuickWindow::afterRendering,
                         d->m_main_win, [resize_timing] {
            resize_timing->rendering_finished_ns.store(resize_timing->elapsedNs());
        }, Qt::DirectConnection);
        QObject::connect(d->m_main_win, &QQuickWindow::frameSwapped,
                         d->m_main_win, [resize_timing] {
            const auto now = resize_timing->elapsedNs();
            if (resize_timing->session_active.load(std::memory_order_acquire)) {
                const std::scoped_lock lock(resize_timing->session_mutex);
                resize_timing->session_frame_timestamps_ns.push_back(now);
            }
            const auto synchronized = resize_timing->synchronized_sequence.load();
            if (synchronized == 0
                || synchronized == resize_timing->reported_swap_sequence.load())
                return;
            resize_timing->reported_swap_sequence.store(synchronized);
            const auto latest = resize_timing->latest_sequence.load();
            const auto changed = resize_timing->latest_change_ns.load();
            const auto synchronized_at = resize_timing->synchronized_ns.load();
            const auto synchronized_after = resize_timing->synchronized_after_ns.load();
            const auto rendering_started = resize_timing->rendering_started_ns.load();
            const auto rendering_finished = resize_timing->rendering_finished_ns.load();
            if (resize_timing->session_active.load(std::memory_order_acquire)) {
                const std::scoped_lock lock(resize_timing->session_mutex);
                resize_timing->session_geometry_to_swap_ns.push_back(now - changed);
                resize_timing->session_sync_to_swap_ns.push_back(now - synchronized_at);
                resize_timing->session_sync_ns.push_back(
                    synchronized_after - synchronized_at);
                resize_timing->session_render_ns.push_back(
                    rendering_finished - rendering_started);
            }
            std::fprintf(stderr,
                         "waywallen resize swap: seq=%d latest=%d pending=%d "
                         "buffer=%dx%d geometry_to_swap_ms=%.3f sync_to_swap_ms=%.3f "
                         "geometry_to_sync_ms=%.3f sync_ms=%.3f render_ms=%.3f "
                         "render_to_swap_ms=%.3f\n",
                         synchronized, latest, qMax(0, latest - synchronized),
                         resize_timing->synchronized_width.load(),
                         resize_timing->synchronized_height.load(),
                         (now - changed) / 1'000'000.0,
                         (now - synchronized_at) / 1'000'000.0,
                         (synchronized_at - changed) / 1'000'000.0,
                         (synchronized_after - synchronized_at) / 1'000'000.0,
                         (rendering_finished - rendering_started) / 1'000'000.0,
                         (now - rendering_finished) / 1'000'000.0);
            std::fflush(stderr);
        }, Qt::DirectConnection);
    }

    // Opt-in output selection for high-refresh visual verification.  Setting
    // QWindow::screen does not synthesize pointer input or activate the
    // window; it only asks the platform plugin to create this test surface on
    // the named output.
    if (const auto requested_screen =
            qEnvironmentVariable("WAYWALLEN_VISUAL_CHECK_SCREEN");
        ! requested_screen.isEmpty()) {
        const auto screens = QGuiApplication::screens();
        const auto found = std::find_if(screens.cbegin(), screens.cend(),
                                        [&requested_screen](const QScreen* screen) {
            return screen && screen->name() == requested_screen;
        });
        if (found != screens.cend()) {
            d->m_main_win->setScreen(*found);
            std::fprintf(stderr,
                         "waywallen visual check: requested_screen=%s active_screen=%s "
                         "refresh_hz=%.3f\n",
                         qPrintable(requested_screen),
                         qPrintable(d->m_main_win->screen()->name()),
                         d->m_main_win->screen()->refreshRate());
        } else {
            std::fprintf(stderr,
                         "waywallen visual check: requested screen not found: %s\n",
                         qPrintable(requested_screen));
        }
        std::fflush(stderr);
    }

    // Narrow the library to one known thumbnail during opt-in visual checks.
    // This changes only the query owned by this test window; it neither edits
    // the persisted filters nor moves focus/pointer state on the desktop.
    if (const auto thumbnail_search =
            qEnvironmentVariable("WAYWALLEN_VISUAL_CHECK_THUMBNAIL_SEARCH");
        ! thumbnail_search.isEmpty()) {
        // Let the initial status/settings requests settle first. Otherwise a
        // slower full-library response can arrive after this focused request
        // and replace its one-item model during capture.
        QTimer::singleShot(1400, d->m_main_win,
                           [window = QPointer<QQuickWindow>(d->m_main_win),
                            thumbnail_search] {
            if (! window) return;
            auto* page = find_visual_item(window->contentItem(), u"wallpaperPage"_s);
            QObject* query = nullptr;
            if (page) {
                const auto descendants = page->findChildren<QObject*>();
                const auto found = std::find_if(
                    descendants.cbegin(), descendants.cend(), [](QObject* object) {
                        return object
                            && QString::fromLatin1(object->metaObject()->className())
                                   .contains(u"WallpaperListQuery"_s)
                            && object->metaObject()->indexOfProperty("searchText") >= 0;
                    });
                if (found != descendants.cend()) query = *found;
            }
            const bool applied = query
                && query->setProperty("searchText", thumbnail_search);
            const bool reloaded = applied
                && QMetaObject::invokeMethod(query, "reload", Qt::DirectConnection);
            std::fprintf(stderr,
                         "waywallen visual check: thumbnail_search=%s applied=%s "
                         "reloaded=%s\n",
                         qPrintable(thumbnail_search), applied ? "true" : "false",
                         reloaded ? "true" : "false");
            std::fflush(stderr);
        });
    }

    // Capture only this process' own surface from the beginning of the first
    // event-loop turn.  The opt-in sequence makes startup transitions
    // inspectable without taking focus, moving the pointer, or using a
    // compositor-wide screenshot API while the desktop is in use.
    if (const auto startup_dir =
            qEnvironmentVariable("WAYWALLEN_VISUAL_CHECK_STARTUP_DIR");
        ! startup_dir.isEmpty()) {
        struct StartupCaptureState {
            QPointer<QQuickWindow> window;
            QPointer<QTimer> timer;
            QString output_dir;
            int frame { 0 };
            int frame_count { 30 };
            QVector<QImage> images;
        };
        auto startup = std::make_shared<StartupCaptureState>();
        startup->window = d->m_main_win;
        startup->output_dir = startup_dir;
        const auto requested_frames = qEnvironmentVariableIntValue(
            "WAYWALLEN_VISUAL_CHECK_STARTUP_FRAMES");
        startup->frame_count = requested_frames > 0 ? requested_frames : 30;
        startup->images.reserve(startup->frame_count);
        QDir().mkpath(startup_dir);

        auto* timer = new QTimer(d->m_main_win);
        startup->timer = timer;
        timer->setTimerType(Qt::PreciseTimer);
        const auto requested_interval = qEnvironmentVariableIntValue(
            "WAYWALLEN_VISUAL_CHECK_STARTUP_INTERVAL_MS");
        timer->setInterval(requested_interval > 0 ? requested_interval : 16);
        QObject::connect(timer, &QTimer::timeout, d->m_main_win, [startup] {
            if (! startup->window) return;

            const auto image = startup->window->grabWindow();
            if (! image.isNull()) startup->images.push_back(image);
            auto* page = find_visual_item(startup->window->contentItem(),
                                          u"wallpaperPage"_s);
            auto* grid = find_visual_item(startup->window->contentItem(),
                                          u"wallpaperPreviewGrid"_s);
            auto* card = find_visual_item(startup->window->contentItem(),
                                          u"wallpaperCard"_s);
            auto* surface = card
                ? find_visual_item(card, u"wallpaperCardSurface"_s) : nullptr;
            const auto scene_position = surface
                ? surface->mapToScene(QPointF {}) : QPointF {};
            std::fprintf(stderr,
                         "waywallen startup frame: i=%d image=%dx%d page=%d "
                         "page_opacity=%.3f page_scale=%.3f grid_visible=%d card=%d "
                         "surface=%.3fx%.3f scene=%.3f,%.3f\n",
                         startup->frame, image.width(), image.height(),
                         page ? 1 : 0, page ? page->opacity() : 0.0,
                         page ? page->scale() : 0.0,
                         grid && grid->isVisible() ? 1 : 0, card ? 1 : 0,
                         surface ? surface->width() : 0.0,
                         surface ? surface->height() : 0.0,
                         scene_position.x(), scene_position.y());
            std::fflush(stderr);

            ++startup->frame;
            if (startup->frame < startup->frame_count) return;
            startup->timer->stop();
            QTimer::singleShot(0, startup->window, [startup] {
                for (qsizetype i = 0; i < startup->images.size(); ++i) {
                    const auto path = QStringLiteral("%1/startup-%2.png")
                        .arg(startup->output_dir)
                        .arg(i, 2, 10, QLatin1Char('0'));
                    QImageWriter writer(path, "PNG");
                    writer.setCompression(1);
                    writer.write(startup->images.at(i));
                }
                std::fprintf(stderr,
                             "waywallen startup frames: saved=%lld dir=%s\n",
                             static_cast<long long>(startup->images.size()),
                             qPrintable(startup->output_dir));
                std::fflush(stderr);
                startup->timer->deleteLater();
            });
        });
        timer->start();
    }

    // Position telemetry complements frameSwapped timing: a fast swap cadence
    // alone cannot say whether a wheel gesture advanced GridView.contentY on
    // every GUI animation tick.  The probe is opt-in so production has no
    // extra timer, property-signal connection, or diagnostic output.
    if (qEnvironmentVariableIsSet("WAYWALLEN_SCROLL_TIMING")) {
        d->m_scroll_timing = std::make_unique<ScrollTimingState>();

        auto* settle_timer = new QTimer(this);
        settle_timer->setSingleShot(true);
        d->m_scroll_timing->settle_timer = settle_timer;
        QObject::connect(settle_timer, &QTimer::timeout, this, [d] {
            if (auto* timing = d->m_scroll_timing.get()) timing->finishIfQuiet();
        });

        auto* discovery_timer = new QTimer(this);
        discovery_timer->setInterval(250);
        d->m_scroll_timing->discovery_timer = discovery_timer;
        QObject::connect(discovery_timer, &QTimer::timeout, this, &App::attachScrollTimingGrid);
        discovery_timer->start();
        QTimer::singleShot(0, this, &App::attachScrollTimingGrid);

        // Qt documents afterAnimating as a GUI-thread callback immediately
        // before scene-graph synchronization.  It is therefore the safe
        // point to sample a QML item's contentY and compare position updates
        // with GUI animation ticks.
        QObject::connect(d->m_main_win, &QQuickWindow::afterAnimating, this, [d] {
            if (auto* timing = d->m_scroll_timing.get()) timing->onAfterAnimating();
        });
        QObject::connect(d->m_main_win, &QQuickWindow::frameSwapped,
                         d->m_main_win, [d] {
            if (auto* timing = d->m_scroll_timing.get()) timing->onFrameSwapped();
        }, Qt::DirectConnection);
    }

    // Opt-in scene graph frame telemetry for release-performance validation.
    // This remains entirely dormant in normal builds and lets the same binary
    // report actual presentation cadence on the user's GPU/output instead of
    // relying on a software-rendered test server.
    if (qEnvironmentVariableIsSet("WAYWALLEN_FRAME_TIMING")) {
        struct FrameTimingState {
            QElapsedTimer clock;
            qint64 last_frame_ns { 0 };
            QVector<qint64> intervals_ns;
        };
        auto timing = std::make_shared<FrameTimingState>();
        timing->clock.start();
        const auto* screen = d->m_main_win->screen();
        std::fprintf(stderr, "waywallen frame timing: enabled platform=%s screen=%s refresh_hz=%.3f\n",
                     qPrintable(QGuiApplication::platformName()),
                     screen ? qPrintable(screen->name()) : "unknown",
                     screen ? screen->refreshRate() : 0.0);
        std::fflush(stderr);
        QObject::connect(d->m_main_win, &QQuickWindow::frameSwapped, d->m_main_win,
                         [timing] {
            const auto now = timing->clock.nsecsElapsed();
            if (timing->last_frame_ns == 0) {
                timing->last_frame_ns = now;
                return;
            }

            const auto interval = now - timing->last_frame_ns;
            timing->last_frame_ns = now;
            // A long idle gap is not a slow frame.  Start a fresh sample run
            // so the report represents an active animation or scroll.
            if (interval > 50'000'000) {
                timing->intervals_ns.clear();
                return;
            }
            timing->intervals_ns.push_back(interval);
            if (timing->intervals_ns.size() < 60)
                return;

            auto sorted = timing->intervals_ns;
            std::sort(sorted.begin(), sorted.end());
            const auto percentile = [&sorted](int percentage) {
                const auto index = qMin(sorted.size() - 1,
                                        (sorted.size() * percentage + 99) / 100 - 1);
                return sorted.at(index);
            };
            const auto total = std::accumulate(sorted.cbegin(), sorted.cend(), qint64 { 0 });
            const auto missed = std::count_if(sorted.cbegin(), sorted.cend(),
                                              [](qint64 value) { return value > 6'150'000; });
            const auto avg_ms = total / double(sorted.size()) / 1'000'000.0;
            const auto avg_fps = avg_ms > 0.0 ? 1'000.0 / avg_ms : 0.0;
            std::fprintf(stderr,
                         "waywallen frame timing: samples=%lld avg_ms=%.3f avg_fps=%.1f "
                         "p95_ms=%.3f p99_ms=%.3f over_165hz=%lld\n",
                         static_cast<long long>(sorted.size()),
                         avg_ms,
                         avg_fps,
                         percentile(95) / 1'000'000.0,
                         percentile(99) / 1'000'000.0,
                         static_cast<long long>(missed));
            std::fflush(stderr);
            timing->intervals_ns.clear();
        }, Qt::DirectConnection);
    }

    // Opt-in, focus-free visual verification for development builds. KWin's
    // screenshot API intentionally rejects unprivileged callers, while
    // QQuickWindow can safely read back only its own rendered surface. This
    // lets automated checks inspect the exact waywallen window without
    // activating it, moving the pointer, or interrupting the desktop session.
    if (const auto output = qEnvironmentVariable("WAYWALLEN_VISUAL_CHECK_OUTPUT");
        ! output.isEmpty()) {
        if (qEnvironmentVariableIsSet("WAYWALLEN_VISUAL_CHECK_ABOUT")) {
            QTimer::singleShot(1200, d->m_main_win.data(),
                               [window = QPointer<QQuickWindow>(d->m_main_win)] {
                if (! window) return;
                const bool invoked = QMetaObject::invokeMethod(
                    window, "showAbout", Qt::DirectConnection);
                std::fprintf(stderr,
                             "waywallen visual check: about_open invoked=%s\n",
                             invoked ? "true" : "false");
                std::fflush(stderr);
            });
        }
        if (const auto resize_dir =
                qEnvironmentVariable("WAYWALLEN_VISUAL_CHECK_RESIZE_DIR");
            ! resize_dir.isEmpty()) {
            struct ResizeCaptureState {
                QPointer<QQuickWindow> window;
                QPointer<QQuickItem> grid;
                QPointer<QTimer> timer;
                QString output_dir;
                int original_width { 0 };
                int target_width { 0 };
                int frame { 0 };
                int frame_count { 24 };
                int hold_frame_count { 0 };
                int width_step { 4 };
                int capture_every { 1 };
                bool grid_only { false };
                bool bounce { false };
                bool zigzag { false };
                int zigzag_span { 12 };
                double original_grid_width { 0.0 };
                QElapsedTimer clock;
                QVector<QImage> images;
                QVector<int> widths;
                QVector<qint64> geometry_timestamps_ns;
                std::chrono::steady_clock::time_point sampling_started;
                std::atomic_bool swap_sampling_active { false };
                std::mutex swap_mutex;
                QVector<qint64> swap_timestamps_ns;

                auto samplingElapsedNs() const -> qint64 {
                    return std::chrono::duration_cast<std::chrono::nanoseconds>(
                        std::chrono::steady_clock::now() - sampling_started).count();
                }
            };
            auto resize = std::make_shared<ResizeCaptureState>();
            resize->window = d->m_main_win;
            resize->output_dir = resize_dir;
            resize->original_width = d->m_main_win->width();
            const auto requested_frames = qEnvironmentVariableIntValue(
                "WAYWALLEN_VISUAL_CHECK_RESIZE_FRAMES");
            const auto requested_step = qEnvironmentVariableIntValue(
                "WAYWALLEN_VISUAL_CHECK_RESIZE_STEP");
            resize->frame_count = requested_frames > 0 ? requested_frames : 24;
            const auto requested_hold_frames = qEnvironmentVariableIntValue(
                "WAYWALLEN_VISUAL_CHECK_RESIZE_HOLD_FRAMES");
            resize->hold_frame_count = qMax(0, requested_hold_frames);
            resize->width_step = requested_step > 0 ? requested_step : 4;
            const auto requested_capture_every = qEnvironmentVariableIntValue(
                "WAYWALLEN_VISUAL_CHECK_RESIZE_CAPTURE_EVERY");
            resize->capture_every = qEnvironmentVariableIsSet(
                "WAYWALLEN_VISUAL_CHECK_RESIZE_CAPTURE_EVERY")
                ? qMax(0, requested_capture_every) : 1;
            resize->grid_only = qEnvironmentVariableIsSet(
                "WAYWALLEN_VISUAL_CHECK_RESIZE_GRID_ONLY");
            const auto resize_pattern = qEnvironmentVariable(
                "WAYWALLEN_VISUAL_CHECK_RESIZE_PATTERN").trimmed().toLower();
            resize->bounce = resize_pattern == u"bounce"_s;
            resize->zigzag = resize_pattern == u"zigzag"_s;
            const auto requested_zigzag_span = qEnvironmentVariableIntValue(
                "WAYWALLEN_VISUAL_CHECK_RESIZE_ZIGZAG_SPAN");
            if (requested_zigzag_span > 1)
                resize->zigzag_span = requested_zigzag_span;
            resize->images.reserve(resize->frame_count + resize->hold_frame_count);
            resize->widths.reserve(resize->frame_count + resize->hold_frame_count);
            resize->geometry_timestamps_ns.reserve(
                resize->frame_count + resize->hold_frame_count);
            resize->swap_timestamps_ns.reserve(
                resize->frame_count + resize->hold_frame_count + 16);
            QDir().mkpath(resize_dir);

            QObject::connect(d->m_main_win, &QQuickWindow::frameSwapped,
                             d->m_main_win, [resize] {
                if (! resize->swap_sampling_active.load(std::memory_order_acquire))
                    return;
                const auto now = resize->samplingElapsedNs();
                const std::scoped_lock lock(resize->swap_mutex);
                resize->swap_timestamps_ns.push_back(now);
            }, Qt::DirectConnection);

            QTimer::singleShot(1600, d->m_main_win, [resize] {
                if (! resize->window) return;
                if (auto* grid = find_visual_item(resize->window->contentItem(),
                                                  u"wallpaperPreviewGrid"_s)) {
                    resize->grid = grid;
                    grid->setProperty("previewAnimationsSettled", false);
                    if (resize->grid_only)
                        grid->setProperty("_diagnosticResizeActive", true);
                    resize->original_grid_width =
                        grid->property("_availableWidth").toDouble();
                }
                auto* timer = new QTimer(resize->window);
                resize->timer = timer;
                const auto requested_interval = qEnvironmentVariableIntValue(
                    "WAYWALLEN_VISUAL_CHECK_RESIZE_INTERVAL_MS");
                timer->setInterval(requested_interval > 0 ? requested_interval : 6);
                timer->setTimerType(Qt::PreciseTimer);
                resize->clock.start();
                resize->sampling_started = std::chrono::steady_clock::now();
                resize->swap_sampling_active.store(true, std::memory_order_release);
                // A real top-level resize suspends KWin's behind-window blur
                // until the configure burst settles.  The GridView-only
                // harness leaves the QQuickWindow geometry fixed, so mirror
                // that compositor state explicitly; otherwise this test pays
                // for a blur pass that production resize deliberately avoids.
                if (resize->grid_only)
                    KWindowEffects::enableBlurBehind(resize->window, false,
                                                     QRegion {});
                QObject::connect(timer, &QTimer::timeout, resize->window,
                                 [resize] {
                    if (! resize->window) return;
                    if (resize->frame
                        >= resize->frame_count + resize->hold_frame_count) {
                        resize->timer->stop();
                        resize->swap_sampling_active.store(false,
                                                           std::memory_order_release);
                        QVector<qint64> swap_timestamps;
                        {
                            const std::scoped_lock lock(resize->swap_mutex);
                            swap_timestamps = resize->swap_timestamps_ns;
                        }
                        const auto intervals = [](const QVector<qint64>& timestamps) {
                            QVector<qint64> result;
                            result.reserve(qMax<qsizetype>(0, timestamps.size() - 1));
                            for (qsizetype i = 1; i < timestamps.size(); ++i)
                                result.push_back(timestamps.at(i) - timestamps.at(i - 1));
                            return result;
                        };
                        const auto geometry_intervals = intervals(
                            resize->geometry_timestamps_ns);
                        const auto swap_intervals = intervals(swap_timestamps);
                        const auto sample_rate = [](const QVector<qint64>& timestamps) {
                            if (timestamps.size() < 2) return 0.0;
                            const auto duration = timestamps.constLast()
                                - timestamps.constFirst();
                            return duration > 0
                                ? (timestamps.size() - 1) * 1'000'000'000.0 / duration
                                : 0.0;
                        };
                        std::fprintf(stderr,
                                     "waywallen resize timing: geometry_frames=%lld "
                                     "geometry_hz=%.1f geometry_p95_ms=%.3f "
                                     "swaps=%lld swap_hz=%.1f swap_p95_ms=%.3f\n",
                                     static_cast<long long>(
                                         resize->geometry_timestamps_ns.size()),
                                     sample_rate(resize->geometry_timestamps_ns),
                                     sample_percentile(geometry_intervals, 95)
                                         / 1'000'000.0,
                                     static_cast<long long>(swap_timestamps.size()),
                                     sample_rate(swap_timestamps),
                                     sample_percentile(swap_intervals, 95)
                                         / 1'000'000.0);
                        std::fflush(stderr);
                        if (auto* grid = resize->grid.data()) {
                            grid->setProperty("previewAnimationsSettled", true);
                            grid->setProperty("_diagnosticAvailableWidthOverride", -1.0);
                            grid->setProperty("_diagnosticResizeActive", false);
                        }
                        if (! resize->grid_only) {
                            resize->window->setWidth(resize->original_width);
                        } else if (auto* window = resize->window.data()) {
                            constexpr int desktop_sidebar_width = 240;
                            constexpr int compact_breakpoint = 600;
                            constexpr int compact_bottom_bar_height = 88;
                            const auto blur_region = window->width() < compact_breakpoint
                                ? QRegion(0,
                                          qMax(0, window->height()
                                              - compact_bottom_bar_height),
                                          qMax(0, window->width()),
                                          qMin(compact_bottom_bar_height,
                                               window->height()))
                                : QRegion(0, 0,
                                          qMin(desktop_sidebar_width,
                                               window->width()),
                                          qMax(0, window->height()));
                            KWindowEffects::enableBlurBehind(window,
                                                             ! blur_region.isEmpty(),
                                                             blur_region);
                        }
                        // Let Wayland commit the restored surface before PNG
                        // compression blocks the GUI thread.
                        QTimer::singleShot(100, resize->window, [resize] {
                            for (qsizetype i = 0; i < resize->images.size(); ++i) {
                                const auto path = QStringLiteral("%1/resize-%2-w%3.png")
                                    .arg(resize->output_dir)
                                    .arg(i, 2, 10, QLatin1Char('0'))
                                    .arg(resize->widths.at(i));
                                QImageWriter writer(path, "PNG");
                                writer.setCompression(1);
                                writer.write(resize->images.at(i));
                            }
                            std::fprintf(stderr,
                                         "waywallen resize frames: saved=%lld dir=%s "
                                         "restored_width=%d\n",
                                         static_cast<long long>(resize->images.size()),
                                         qPrintable(resize->output_dir),
                                         resize->original_width);
                            std::fflush(stderr);
                            resize->timer->deleteLater();
                        });
                        return;
                    }

                    const bool capture_image = ! resize->grid_only
                        && resize->capture_every > 0
                        && resize->frame % resize->capture_every == 0;
                    const auto image = capture_image
                        ? resize->window->grabWindow() : QImage {};
                    const auto dpr = resize->window->devicePixelRatio();
                    const auto expected_image_width = qRound(resize->target_width * dpr);
                    // A top-level Wayland resize completes asynchronously.
                    // Do not advance the trajectory until the compositor has
                    // acknowledged the requested logical width, even in the
                    // no-PNG performance pass; otherwise the timer cadence is
                    // incorrectly reported as window-resize throughput.
                    if (! resize->grid_only
                        && resize->window->width() != resize->target_width) {
                        return;
                    }
                    if (capture_image
                        && std::abs(image.width() - expected_image_width) > 1) {
                        std::fprintf(stderr,
                                     "waywallen resize frame wait: i=%d target_w=%d "
                                     "image_w=%d expected_w=%d dpr=%.3f\n",
                                     resize->frame, resize->target_width, image.width(),
                                     expected_image_width, dpr);
                        std::fflush(stderr);
                        return;
                    }
                    if (capture_image) {
                        resize->images.push_back(image);
                        resize->widths.push_back(resize->window->width());
                    }

                    auto* grid = resize->grid.data();
                    // The high-rate geometry-only pass deliberately avoids
                    // walking every delegate and formatting source paths.
                    // Those details belong to the lower-rate PNG pass and
                    // would otherwise distort the cadence being measured.
                    const bool lightweight = resize->grid_only
                        || resize->capture_every == 0;
                    auto* card = lightweight ? nullptr
                        : find_visual_item(resize->window->contentItem(),
                                           u"wallpaperCard"_s);
                    auto* surface = card
                        ? find_visual_item(card, u"wallpaperCardSurface"_s) : nullptr;
                    auto* thumbnail = card
                        ? find_visual_item(card, u"wallpaperThumbnail"_s) : nullptr;
                    const auto scene_position = surface
                        ? surface->mapToScene(QPointF {}) : QPointF {};
                    const auto geometry_timestamp = resize->samplingElapsedNs();
                    resize->geometry_timestamps_ns.push_back(geometry_timestamp);
                    QVector<QQuickItem*> cards;
                    if (! lightweight)
                        collect_visual_items(resize->window->contentItem(),
                                             u"wallpaperCard"_s, cards);
                    std::sort(cards.begin(), cards.end(), [](QQuickItem* lhs,
                                                             QQuickItem* rhs) {
                        return lhs->property("index").toInt()
                            < rhs->property("index").toInt();
                    });
                    QString first_row;
                    for (auto* row_card : cards) {
                        const auto index = row_card->property("index").toInt();
                        if (index < 0 || index >= 6) continue;
                        auto* row_surface = find_visual_item(row_card,
                                                            u"wallpaperCardSurface"_s);
                        if (! row_surface) continue;
                        const auto position = row_surface->mapToScene(QPointF {});
                        first_row += QStringLiteral(" %1:%2/%3")
                            .arg(index).arg(position.x()).arg(row_surface->width());
                    }
                    std::fprintf(stderr,
                                 "waywallen resize frame: i=%d t_ms=%.3f target_w=%d window_w=%d "
                                 "grid_only=%d "
                                 "grid_w=%.3f cols=%d cell_w=%.3f display_w=%.3f "
                                 "card_index=%d card=%.3fx%.3f surface_local=%.3f,%.3f "
                                 "surface_w=%.3f surface_h=%.3f "
                                 "surface_scene=%.3f,%.3f source=%s dpr=%.3f image=%dx%d "
                                 "first_row=[%s]\n",
                                 resize->frame,
                                 geometry_timestamp / 1'000'000.0,
                                 resize->target_width,
                                 resize->window->width(),
                                 resize->grid_only ? 1 : 0,
                                 grid ? grid->width() : 0.0,
                                 grid ? grid->property("_cols").toInt() : 0,
                                 grid ? grid->property("cellWidth").toDouble() : 0.0,
                                 grid ? grid->property("_displayItemWidth").toDouble() : 0.0,
                                 card ? card->property("index").toInt() : -1,
                                 card ? card->width() : 0.0, card ? card->height() : 0.0,
                                 surface ? surface->x() : 0.0, surface ? surface->y() : 0.0,
                                 surface ? surface->width() : 0.0,
                                 surface ? surface->height() : 0.0,
                                 scene_position.x(), scene_position.y(),
                                 thumbnail
                                     ? qPrintable(thumbnail->property("source").toString()) : "",
                                 dpr, image.width(), image.height(), qPrintable(first_row));
                    std::fflush(stderr);
                    ++resize->frame;
                    if (resize->frame < resize->frame_count) {
                        const auto original = resize->grid_only
                            ? qRound(resize->original_grid_width)
                            : resize->original_width;
                        const auto next_frame = resize->frame;
                        const auto zigzag_phase = resize->zigzag
                            ? (next_frame + 1) % (2 * resize->zigzag_span) : 0;
                        const auto distance_steps = resize->zigzag
                            ? (zigzag_phase <= resize->zigzag_span
                                ? zigzag_phase
                                : 2 * resize->zigzag_span - zigzag_phase)
                            : resize->bounce
                                ? qMin(next_frame + 1,
                                       qMax(0, resize->frame_count - next_frame - 1))
                                : next_frame + 1;
                        resize->target_width = original
                            - distance_steps * resize->width_step;
                        if (resize->grid_only && grid)
                            grid->setProperty("_diagnosticAvailableWidthOverride",
                                              resize->target_width);
                        else
                            resize->window->setWidth(resize->target_width);
                    }
                });
                const auto original = resize->grid_only
                    ? qRound(resize->original_grid_width)
                    : resize->original_width;
                const auto first_distance_steps = resize->bounce || resize->zigzag
                    ? qMin(1, qMax(0, resize->frame_count - 1)) : 1;
                resize->target_width = original
                    - first_distance_steps * resize->width_step;
                if (resize->grid_only) {
                    if (auto* grid = resize->grid.data())
                        grid->setProperty("_diagnosticAvailableWidthOverride",
                                          resize->target_width);
                } else {
                    resize->window->setWidth(resize->target_width);
                }
                timer->start();
            });
        }

        // A synthetic event is available only to the opt-in verification
        // run. It is delivered to this QQuickWindow directly, so it cannot
        // move the user's desktop pointer or scroll another application.
        if (qEnvironmentVariableIsSet("WAYWALLEN_VISUAL_CHECK_WHEEL")) {
            const auto requested_page =
                qEnvironmentVariable("WAYWALLEN_VISUAL_CHECK_WHEEL_PAGE")
                    .trimmed().toLower();
            const bool discover_page = requested_page == u"discover"_s;
            const bool status_page = requested_page == u"status"_s;
            const auto grid_object_name = status_page
                ? u"statusScrollView"_s
                : discover_page ? u"discoverPreviewGrid"_s
                                : u"wallpaperPreviewGrid"_s;
            const auto page_name = status_page
                ? u"status"_s : discover_page ? u"discover"_s : u"wallpaper"_s;
            if (discover_page || status_page) {
                QTimer::singleShot(250, d->m_main_win,
                                   [window = QPointer<QQuickWindow>(d->m_main_win),
                                    status_page] {
                    if (window) window->setProperty("currentPage",
                                                    status_page ? 3 : 1);
                });
            }
            const auto requested_wheel_delay = qEnvironmentVariableIntValue(
                "WAYWALLEN_VISUAL_CHECK_WHEEL_DELAY_MS");
            const auto wheel_delay = requested_wheel_delay > 0
                ? qBound(250, requested_wheel_delay, 30'000)
                : discover_page ? 3500 : 1500;
            QTimer::singleShot(wheel_delay, d->m_main_win,
                               [window = QPointer<QQuickWindow>(d->m_main_win),
                                grid_object_name, page_name, discover_page] {
                if (! window) return;
                auto* grid = find_visual_item(window->contentItem(),
                                              grid_object_name);
                if (! grid) {
                    std::fprintf(stderr,
                                 "waywallen visual check: native_wheel page=%s grid_missing\n",
                                 qPrintable(page_name));
                    std::fflush(stderr);
                    return;
                }
                QVector<QQuickItem*> thumbnail_items;
                collect_visual_items(
                    grid,
                    discover_page ? u"discoverThumbnail"_s : u"wallpaperThumbnail"_s,
                    thumbnail_items);
                const auto ready_thumbnails = std::count_if(
                    thumbnail_items.cbegin(), thumbnail_items.cend(), [](QQuickItem* item) {
                        return item && item->property("contentReady").toBool();
                    });
                std::fprintf(
                    stderr,
                    "waywallen visual check: grid count=%d visible=%s columns=%d "
                    "cell=%.1fx%.1f display_item=%.1fx%.1f window_dpr=%.3f "
                    "delegates=%lld geometry_valid=%s thumbnail_ready=%lld/%lld\n",
                    grid->property("count").toInt(), grid->isVisible() ? "true" : "false",
                    grid->property("_cols").toInt(),
                    grid->property("cellWidth").toDouble(),
                    grid->property("cellHeight").toDouble(),
                    grid->property("_displayItemWidth").toDouble(),
                    grid->property("_displayItemHeight").toDouble(),
                    window->devicePixelRatio(),
                    static_cast<long long>(thumbnail_items.size()),
                    grid->property("cellWidth").toDouble() > 0.0
                            && grid->property("cellHeight").toDouble() > 0.0
                        ? "true" : "false",
                    static_cast<long long>(ready_thumbnails),
                    static_cast<long long>(thumbnail_items.size()));
                std::fflush(stderr);
                if (qEnvironmentVariableIsSet(
                        "WAYWALLEN_VISUAL_CHECK_DUMP_THUMBNAILS")) {
                    for (auto* thumbnail : thumbnail_items) {
                        if (! thumbnail) continue;
                        QObject* card = thumbnail;
                        while (card
                               && card->metaObject()->indexOfProperty("title") < 0)
                            card = card->parent();
                        const auto title = card
                            ? card->property("title").toString() : QString {};
                        const auto source = thumbnail->property("source").toString();
                        std::fprintf(
                            stderr,
                            "waywallen thumbnail source: ready=%d status=%d "
                            "title=%s source=%s\n",
                            thumbnail->property("contentReady").toBool() ? 1 : 0,
                            thumbnail->property("status").toInt(),
                            qPrintable(title.simplified()), qPrintable(source));
                    }
                    std::fflush(stderr);
                }
                // Position an opt-in cold-thumbnail probe directly on a
                // requested model row. The lookup scans string roles instead
                // of depending on a particular generated protobuf role name,
                // so it remains useful across model schema revisions.
                if (const auto thumbnail_target = qEnvironmentVariable(
                        "WAYWALLEN_VISUAL_CHECK_THUMBNAIL_TARGET");
                    ! thumbnail_target.isEmpty()) {
                    auto* model_object = grid->property("model").value<QObject*>();
                    auto* model = qobject_cast<QAbstractItemModel*>(model_object);
                    int target_index = -1;
                    QByteArray target_role;
                    if (model) {
                        const auto roles = model->roleNames();
                        for (int row = 0; row < model->rowCount() && target_index < 0; ++row) {
                            const auto model_index = model->index(row, 0);
                            for (auto role = roles.cbegin(); role != roles.cend(); ++role) {
                                const auto value = model->data(model_index, role.key()).toString();
                                if (value.contains(thumbnail_target, Qt::CaseInsensitive)) {
                                    target_index = row;
                                    target_role = role.value();
                                    break;
                                }
                            }
                        }
                    }
                    if (target_index >= 0) {
                        const int columns = qMax(1, grid->property("_cols").toInt());
                        const int row = target_index / columns;
                        const int column = target_index % columns;
                        const double cell_height = grid->property("cellHeight").toDouble();
                        const double top_margin = grid->property("topMargin").toDouble();
                        const double bottom_margin = grid->property("bottomMargin").toDouble();
                        const double minimum_y = -top_margin;
                        const double maximum_y = qMax(
                            minimum_y,
                            grid->property("contentHeight").toDouble() - grid->height()
                                + bottom_margin);
                        const double target_y = qBound(
                            minimum_y,
                            row * cell_height - (grid->height() - cell_height) / 2.0,
                            maximum_y);
                        grid->setProperty("currentIndex", target_index);
                        grid->setProperty("contentY", target_y);
                        grid->setProperty("previewAnimationsSettled", true);
                        std::fprintf(
                            stderr,
                            "waywallen visual check: thumbnail_target=%s found=true "
                            "index=%d row=%d column=%d role=%s content_y=%.3f\n",
                            qPrintable(thumbnail_target), target_index, row, column,
                            target_role.constData(), target_y);
                    } else {
                        std::fprintf(stderr,
                                     "waywallen visual check: thumbnail_target=%s "
                                     "found=false model=%s rows=%d\n",
                                     qPrintable(thumbnail_target),
                                     model_object
                                         ? model_object->metaObject()->className() : "null",
                                     model ? model->rowCount() : 0);
                    }
                    std::fflush(stderr);
                }
                const auto before = grid->property("contentY").toDouble();
                const auto position = grid->mapToScene(
                    QPointF(grid->width() / 2.0, grid->height() / 2.0));
                const auto requested_steps = qEnvironmentVariableIntValue(
                    "WAYWALLEN_VISUAL_CHECK_WHEEL_STEPS");
                // Long opt-in sweeps exercise delegate reuse from the first
                // library row through the final one. Production input never
                // reaches this synthetic-event branch.
                const auto steps = qBound(1, requested_steps > 0 ? requested_steps : 1, 80);
                const auto requested_step_interval = qEnvironmentVariableIntValue(
                    "WAYWALLEN_VISUAL_CHECK_WHEEL_STEP_INTERVAL_MS");
                const auto step_interval = qBound(
                    16, requested_step_interval > 0 ? requested_step_interval : 80, 500);
                auto sent_count = std::make_shared<int>(0);

                // Optionally capture only this test process' surface while
                // the wheel trajectory is in flight. This is deliberately a
                // separate run from performance timing because grabWindow()
                // itself adds synchronization cost.
                if (const auto capture_dir = qEnvironmentVariable(
                        "WAYWALLEN_VISUAL_CHECK_WHEEL_DIR");
                    ! capture_dir.isEmpty()) {
                    struct WheelCaptureState {
                        QPointer<QQuickWindow> window;
                        QPointer<QTimer> timer;
                        QString output_dir;
                        QString grid_object_name;
                        QString scroll_bar_object_name;
                        QString page_name;
                        int frame { 0 };
                        int frame_count { 16 };
                        int capture_every { 1 };
                        QVector<QPair<int, QImage>> images;
                    };
                    auto capture = std::make_shared<WheelCaptureState>();
                    capture->window = window;
                    capture->output_dir = capture_dir;
                    capture->grid_object_name = grid_object_name;
                    capture->scroll_bar_object_name = discover_page
                        ? u"discoverPreviewScrollBar"_s
                        : u"wallpaperPreviewScrollBar"_s;
                    capture->page_name = page_name;
                    const auto requested_frames = qEnvironmentVariableIntValue(
                        "WAYWALLEN_VISUAL_CHECK_WHEEL_FRAMES");
                    capture->frame_count = requested_frames > 0 ? requested_frames : 16;
                    const auto requested_capture_every = qEnvironmentVariableIntValue(
                        "WAYWALLEN_VISUAL_CHECK_WHEEL_CAPTURE_EVERY");
                    capture->capture_every = qBound(
                        1, requested_capture_every > 0 ? requested_capture_every : 1, 60);
                    capture->images.reserve(
                        (capture->frame_count + capture->capture_every - 1)
                        / capture->capture_every);
                    QDir().mkpath(capture_dir);

                    auto* capture_timer = new QTimer(window);
                    capture->timer = capture_timer;
                    capture_timer->setTimerType(Qt::PreciseTimer);
                    const auto requested_interval = qEnvironmentVariableIntValue(
                        "WAYWALLEN_VISUAL_CHECK_WHEEL_CAPTURE_INTERVAL_MS");
                    capture_timer->setInterval(requested_interval > 0
                                                   ? requested_interval : 12);
                    QObject::connect(capture_timer, &QTimer::timeout, window,
                                     [capture] {
                        if (! capture->window) return;
                        auto* captured_grid = find_visual_item(
                            capture->window->contentItem(), capture->grid_object_name);
                        auto* scroll_bar = find_visual_item(
                            capture->window->contentItem(),
                            capture->scroll_bar_object_name);
                        const bool capture_image = capture->frame % capture->capture_every == 0
                            || capture->frame + 1 == capture->frame_count;
                        const auto image = capture_image
                            ? capture->window->grabWindow() : QImage {};
                        if (! image.isNull())
                            capture->images.push_back({ capture->frame, image });
                        std::fprintf(stderr,
                                     "waywallen wheel frame: page=%s i=%d "
                                     "content_y=%.3f image=%dx%d scrollbar_visible=%d "
                                     "scrollbar_active=%d scrollbar_position=%.5f "
                                     "scrollbar_size=%.5f\n",
                                     qPrintable(capture->page_name), capture->frame,
                                     captured_grid
                                         ? captured_grid->property("contentY").toDouble()
                                         : 0.0,
                                     capture->window->width(), capture->window->height(),
                                     scroll_bar && scroll_bar->isVisible() ? 1 : 0,
                                     scroll_bar
                                         ? scroll_bar->property("active").toBool() : 0,
                                     scroll_bar
                                         ? scroll_bar->property("position").toDouble() : 0.0,
                                     scroll_bar
                                         ? scroll_bar->property("size").toDouble() : 0.0);
                        std::fflush(stderr);

                        ++capture->frame;
                        if (capture->frame < capture->frame_count) return;
                        capture->timer->stop();
                        QTimer::singleShot(0, capture->window, [capture] {
                            for (const auto& [frame, image] : capture->images) {
                                const auto path = QStringLiteral("%1/wheel-%2.png")
                                    .arg(capture->output_dir)
                                    .arg(frame, 3, 10, QLatin1Char('0'));
                                QImageWriter writer(path, "PNG");
                                writer.setCompression(1);
                                writer.write(image);
                            }
                            std::fprintf(stderr,
                                         "waywallen wheel frames: page=%s saved=%lld dir=%s\n",
                                         qPrintable(capture->page_name),
                                         static_cast<long long>(capture->images.size()),
                                         qPrintable(capture->output_dir));
                            std::fflush(stderr);
                            capture->timer->deleteLater();
                        });
                    });
                    capture_timer->start();
                }

                for (int step = 0; step < steps; ++step) {
                    QTimer::singleShot(step * step_interval, window,
                                       [window = QPointer<QQuickWindow>(window), position,
                                        sent_count] {
                        if (! window) return;
                        // Some Wayland seats expose only their touchpad until
                        // a physical mouse sends input. Use an explicit test
                        // device so the Mouse-only handler is deterministic.
                        const QPointingDevice test_mouse {
                            QStringLiteral("waywallen-visual-check-mouse"), 0x57574c,
                            QInputDevice::DeviceType::Mouse,
                            QPointingDevice::PointerType::Generic,
                            QInputDevice::Capability::Position
                                | QInputDevice::Capability::Scroll,
                            1, 3
                        };
                        QWheelEvent event(
                            position,
                            QPointF(window->mapToGlobal(position.toPoint())),
                            QPoint {}, QPoint { 0, -120 }, Qt::NoButton,
                            Qt::NoModifier, Qt::NoScrollPhase, false,
                            Qt::MouseEventNotSynthesized, &test_mouse);
                        if (QCoreApplication::sendEvent(window, &event))
                            ++*sent_count;
                    });
                }

                QTimer::singleShot((steps - 1) * step_interval + 240, window,
                                   [window = QPointer<QQuickWindow>(window), before,
                                    sent_count, steps, grid_object_name, page_name] {
                    if (! window) return;
                    auto* checked_grid = find_visual_item(window->contentItem(),
                                                          grid_object_name);
                    const auto after = checked_grid
                        ? checked_grid->property("contentY").toDouble() : before;
                    std::fprintf(stderr,
                                 "waywallen visual check: native_wheel page=%s sent=%d steps=%d "
                                 "count=%d content_height=%.3f viewport_height=%.3f "
                                 "before=%.3f after=%.3f delta=%.3f\n",
                                 qPrintable(page_name), *sent_count, steps,
                                 checked_grid ? checked_grid->property("count").toInt() : 0,
                                 checked_grid
                                     ? checked_grid->property("contentHeight").toDouble() : 0.0,
                                 checked_grid ? checked_grid->height() : 0.0,
                                 before, after,
                                 after - before);
                    std::fflush(stderr);
                });

                // Opt-in boundary regression for the real failure sequence:
                // wheel to the lower extent, wait for preview playback to
                // resume, then move to the upper extent as a ScrollBar drag
                // would.  A stale wheel timer used to pull contentY back to
                // the bottom after this direct position change.
                if (qEnvironmentVariableIsSet(
                        "WAYWALLEN_VISUAL_CHECK_BOTTOM_REGRESSION")) {
                    const int settle_delay = (steps - 1) * step_interval + 700;
                    QTimer::singleShot(
                        settle_delay, window,
                        [window = QPointer<QQuickWindow>(window), grid_object_name,
                         page_name] {
                        if (! window) return;
                        auto* checked_grid = find_visual_item(
                            window->contentItem(), grid_object_name);
                        if (! checked_grid) return;
                        const double origin_y = checked_grid->property("originY").toDouble();
                        const double top_margin = checked_grid->property("topMargin").toDouble();
                        const double bottom_margin =
                            checked_grid->property("bottomMargin").toDouble();
                        const double minimum_y = origin_y - top_margin;
                        const double maximum_y = qMax(
                            minimum_y,
                            origin_y + checked_grid->property("contentHeight").toDouble()
                                - checked_grid->height() + bottom_margin);
                        const double bottom_y =
                            checked_grid->property("contentY").toDouble();
                        const bool previews_settled = checked_grid
                            ->property("previewAnimationsSettled").toBool();
                        std::fprintf(
                            stderr,
                            "waywallen bottom regression: page=%s phase=bottom "
                            "content_y=%.3f expected=%.3f distance=%.3f "
                            "preview_settled=%d\n",
                            qPrintable(page_name), bottom_y, maximum_y,
                            std::abs(maximum_y - bottom_y), previews_settled ? 1 : 0);
                        std::fflush(stderr);

                        checked_grid->setProperty("contentY", minimum_y);
                        QTimer::singleShot(
                            350, window,
                            [window, grid_object_name, page_name, minimum_y,
                             maximum_y, bottom_y, previews_settled] {
                            if (! window) return;
                            auto* final_grid = find_visual_item(
                                window->contentItem(), grid_object_name);
                            if (! final_grid) return;
                            const double final_y =
                                final_grid->property("contentY").toDouble();
                            const bool final_settled = final_grid
                                ->property("previewAnimationsSettled").toBool();
                            const bool pass = std::abs(maximum_y - bottom_y) < 1.0
                                && previews_settled
                                && std::abs(final_y - minimum_y) < 0.5
                                && final_settled;
                            std::fprintf(
                                stderr,
                                "waywallen bottom regression: page=%s phase=top "
                                "content_y=%.3f expected=%.3f distance=%.3f "
                                "preview_settled=%d result=%s\n",
                                qPrintable(page_name), final_y, minimum_y,
                                std::abs(final_y - minimum_y),
                                final_settled ? 1 : 0, pass ? "PASS" : "FAIL");
                            std::fflush(stderr);
                        });
                    });
                }
            });
        }

        // Optionally exercise the card -> detail-panel transition without
        // synthesizing desktop input or activating the application window.
        // Invoking a delegate's existing signal takes the same QML
        // code path as a click, while leaving the user's pointer and focus
        // untouched.
        if (qEnvironmentVariableIsSet("WAYWALLEN_VISUAL_CHECK_OPEN_DETAIL")) {
            QTimer::singleShot(2000, d->m_main_win,
                               [window = QPointer<QQuickWindow>(d->m_main_win)] {
                if (! window) return;
                auto* card = find_visual_item(window->contentItem(), u"wallpaperCard"_s);
                const int requested_detail_index =
                    qEnvironmentVariableIntValue("WAYWALLEN_VISUAL_CHECK_DETAIL_INDEX");
                if (requested_detail_index >= 0) {
                    QVector<QQuickItem*> cards;
                    collect_visual_items(window->contentItem(), u"wallpaperCard"_s,
                                         cards);
                    for (auto* candidate : cards) {
                        if (candidate
                            && candidate->property("index").toInt()
                                == requested_detail_index) {
                            card = candidate;
                            break;
                        }
                    }
                }

                struct DetailTransitionSample {
                    qint64 time_ns { 0 };
                    double progress { 0.0 };
                    int columns { 0 };
                    double cell_width { 0.0 };
                    double display_width { 0.0 };
                    double surface_width { 0.0 };
                    double viewport_width { 0.0 };
                    double layout_width { 0.0 };
                    double content_y { 0.0 };
                    double current_item_y { 0.0 };
                    double grid_height { 0.0 };
                    double origin_y { 0.0 };
                    double top_margin { 0.0 };
                    double bottom_margin { 0.0 };
                    double current_scene_center_y { 0.0 };
                    bool current_visible { false };
                };
                struct DetailTransitionTrace {
                    QPointer<QQuickWindow> window;
                    QPointer<QQuickItem> initial_card;
                    QElapsedTimer clock;
                    QVector<DetailTransitionSample> samples;
                    QString capture_dir;
                    QVector<QImage> captures;
                    int sample_index { 0 };
                    QMetaObject::Connection animation_connection;
                };
                auto trace = std::make_shared<DetailTransitionTrace>();
                trace->window = window;
                trace->initial_card = card;
                trace->samples.reserve(64);
                trace->capture_dir = qEnvironmentVariable(
                    "WAYWALLEN_VISUAL_CHECK_DETAIL_DIR");
                if (! trace->capture_dir.isEmpty()) {
                    QDir().mkpath(trace->capture_dir);
                    trace->captures.reserve(32);
                }
                trace->clock.start();
                const auto sample_detail = [trace] {
                    if (! trace->window) return;
                    auto* page = find_visual_item(trace->window->contentItem(),
                                                  u"wallpaperPage"_s);
                    auto* grid = find_visual_item(trace->window->contentItem(),
                                                  u"wallpaperPreviewGrid"_s);
                    if (! page || ! grid) return;
                    auto* current_item = qobject_cast<QQuickItem*>(
                        grid->property("currentItem").value<QObject*>());
                    auto* card_item = current_item ? current_item
                                                   : trace->initial_card.data();
                    auto* surface = find_visual_item(card_item,
                                                     u"wallpaperCardSurface"_s);
                    const auto content_y = grid->property("contentY").toDouble();
                    const auto visible_top = content_y
                        + grid->property("topMargin").toDouble();
                    const auto visible_bottom = content_y + grid->height()
                        - grid->property("bottomMargin").toDouble();
                    const bool current_visible = card_item
                        && card_item->y() + card_item->height() > visible_top
                        && card_item->y() < visible_bottom;
                    const auto current_scene_center = surface
                        ? surface->mapToScene(QPointF { surface->width() / 2.0,
                                                       surface->height() / 2.0 })
                        : QPointF {};
                    trace->samples.push_back(DetailTransitionSample {
                        .time_ns = trace->clock.nsecsElapsed(),
                        .progress = page->property("detailPanelProgress").toDouble(),
                        .columns = grid->property("_cols").toInt(),
                        .cell_width = grid->property("cellWidth").toDouble(),
                        .display_width = grid->property("_displayItemWidth").toDouble(),
                        .surface_width = surface ? surface->width() : 0.0,
                        .viewport_width = grid->width(),
                        .layout_width = grid->property("_availableWidth").toDouble(),
                        .content_y = content_y,
                        .current_item_y = card_item ? card_item->y() : 0.0,
                        .grid_height = grid->height(),
                        .origin_y = grid->property("originY").toDouble(),
                        .top_margin = grid->property("topMargin").toDouble(),
                        .bottom_margin = grid->property("bottomMargin").toDouble(),
                        .current_scene_center_y = current_scene_center.y(),
                        .current_visible = current_visible,
                    });
                    if (! trace->capture_dir.isEmpty()
                        && trace->sample_index % 2 == 0
                        && trace->captures.size() < 32) {
                        const auto image = trace->window->grabWindow();
                        if (! image.isNull()) trace->captures.push_back(image);
                    }
                    ++trace->sample_index;
                };

                // Preserve the pre-click geometry as frame zero, then sample
                // every GUI animation tick without taking screenshots or
                // writing to stderr in the hot path.
                sample_detail();
                const bool invoked = card
                    && QMetaObject::invokeMethod(card, "clicked", Qt::DirectConnection,
                                                 Q_ARG(int, 0));
                trace->animation_connection = QObject::connect(
                    window, &QQuickWindow::afterAnimating, window, sample_detail);
                std::fprintf(stderr,
                             "waywallen visual check: detail_click invoked=%s\n",
                             invoked ? "true" : "false");
                std::fflush(stderr);

                QTimer::singleShot(320, window, [trace, sample_detail] {
                    if (! trace->window) return;
                    QObject::disconnect(trace->animation_connection);
                    sample_detail();
                    for (qsizetype i = 0; i < trace->samples.size(); ++i) {
                        const auto& sample = trace->samples.at(i);
                        std::fprintf(
                            stderr,
                            "waywallen detail frame: i=%lld t_ms=%.3f progress=%.4f "
                            "cols=%d cell_w=%.3f display_w=%.3f surface_w=%.3f "
                            "viewport_w=%.3f layout_w=%.3f content_y=%.3f "
                            "current_item_y=%.3f grid_h=%.3f origin_y=%.3f "
                            "top_margin=%.3f bottom_margin=%.3f "
                            "current_scene_center_y=%.3f current_visible=%d\n",
                            static_cast<long long>(i), sample.time_ns / 1'000'000.0,
                            sample.progress, sample.columns, sample.cell_width,
                            sample.display_width, sample.surface_width,
                            sample.viewport_width, sample.layout_width,
                            sample.content_y, sample.current_item_y,
                            sample.grid_height, sample.origin_y,
                            sample.top_margin, sample.bottom_margin,
                            sample.current_scene_center_y,
                            sample.current_visible ? 1 : 0);
                    }
                    for (qsizetype i = 0; i < trace->captures.size(); ++i) {
                        const auto path = QStringLiteral("%1/open-%2.png")
                            .arg(trace->capture_dir)
                            .arg(i, 3, 10, QLatin1Char('0'));
                        QImageWriter writer(path, "PNG");
                        writer.setCompression(1);
                        writer.write(trace->captures.at(i));
                    }
                    if (! trace->capture_dir.isEmpty()) {
                        std::fprintf(stderr,
                                     "waywallen detail frames: saved=%lld dir=%s\n",
                                     static_cast<long long>(trace->captures.size()),
                                     qPrintable(trace->capture_dir));
                    }
                    std::fflush(stderr);
                });
                QTimer::singleShot(100, window,
                                   [window = QPointer<QQuickWindow>(window)] {
                    if (! window) return;
                    if (auto* page = find_visual_item(window->contentItem(),
                                                      u"wallpaperPage"_s)) {
                        std::fprintf(stderr,
                                     "waywallen visual check: detail_transition "
                                     "progress=%.3f\n",
                                     page->property("detailPanelProgress").toDouble());
                        std::fflush(stderr);
                    }
                });

                if (qEnvironmentVariableIsSet(
                        "WAYWALLEN_VISUAL_CHECK_SWITCH_DETAIL")) {
                    QTimer::singleShot(
                        360, window,
                        [window = QPointer<QQuickWindow>(window)] {
                        if (! window) return;
                        auto* grid = find_visual_item(window->contentItem(),
                                                      u"wallpaperPreviewGrid"_s);
                        if (! grid) return;
                        QVector<QQuickItem*> cards;
                        collect_visual_items(grid, u"wallpaperCard"_s, cards);
                        const int old_index = grid->property("currentIndex").toInt();
                        const int columns = qMax(1, grid->property("_cols").toInt());
                        const int desired_index = old_index + columns * 3;
                        QQuickItem* old_card = nullptr;
                        QQuickItem* target = nullptr;
                        int target_index = -1;
                        for (auto* candidate : cards) {
                            if (! candidate || ! candidate->isVisible()) continue;
                            const int index = candidate->property("index").toInt();
                            if (index == old_index) {
                                old_card = candidate;
                                continue;
                            }
                            if (! target
                                || std::abs(index - desired_index)
                                    < std::abs(target_index - desired_index)) {
                                target = candidate;
                                target_index = index;
                            }
                            if (index == desired_index) break;
                        }
                        const double content_y_before =
                            grid->property("contentY").toDouble();
                        struct DetailSwitchTrace {
                            QPointer<QQuickWindow> window;
                            double content_y_before { 0.0 };
                            double min_content_y { 0.0 };
                            double max_content_y { 0.0 };
                            QPointer<QQuickItem> old_frame;
                            QPointer<QQuickItem> target_frame;
                            QVector<QPair<double, double>> frame_opacities;
                            QVector<double> content_positions;
                            QMetaObject::Connection connection;
                            int old_index { -1 };
                            int target_index { -1 };
                        };
                        auto switch_trace = std::make_shared<DetailSwitchTrace>();
                        switch_trace->window = window;
                        switch_trace->content_y_before = content_y_before;
                        switch_trace->min_content_y = content_y_before;
                        switch_trace->max_content_y = content_y_before;
                        switch_trace->old_index = old_index;
                        switch_trace->target_index = target_index;
                        switch_trace->old_frame = find_visual_item(
                            old_card, u"wallpaperSelectionFrame"_s);
                        switch_trace->target_frame = find_visual_item(
                            target, u"wallpaperSelectionFrame"_s);
                        const auto sample_switch = [switch_trace] {
                            if (! switch_trace->window) return;
                            auto* sampled_grid = find_visual_item(
                                switch_trace->window->contentItem(),
                                u"wallpaperPreviewGrid"_s);
                            if (! sampled_grid) return;
                            const double y =
                                sampled_grid->property("contentY").toDouble();
                            switch_trace->min_content_y =
                                std::min(switch_trace->min_content_y, y);
                            switch_trace->max_content_y =
                                std::max(switch_trace->max_content_y, y);
                            switch_trace->content_positions.push_back(y);
                            switch_trace->frame_opacities.push_back({
                                switch_trace->old_frame
                                    ? switch_trace->old_frame->opacity() : 0.0,
                                switch_trace->target_frame
                                    ? switch_trace->target_frame->opacity() : 0.0,
                            });
                        };
                        sample_switch();
                        switch_trace->connection = QObject::connect(
                            window, &QQuickWindow::afterAnimating, window,
                            sample_switch);
                        const bool invoked = target
                            && QMetaObject::invokeMethod(
                                target, "clicked", Qt::DirectConnection,
                                Q_ARG(int, 0));
                        std::fprintf(
                            stderr,
                            "waywallen detail switch: phase=start old_index=%d "
                            "target_index=%d content_y=%.3f invoked=%d\n",
                            old_index, target_index, content_y_before,
                            invoked ? 1 : 0);
                        std::fflush(stderr);

                        QTimer::singleShot(450, window,
                                           [switch_trace, sample_switch] {
                            if (! switch_trace->window) return;
                            QObject::disconnect(switch_trace->connection);
                            sample_switch();
                            auto* final_grid = find_visual_item(
                                switch_trace->window->contentItem(),
                                u"wallpaperPreviewGrid"_s);
                            const int final_index = final_grid
                                ? final_grid->property("currentIndex").toInt() : -1;
                            int transition_samples = 0;
                            for (qsizetype i = 1;
                                 i < switch_trace->frame_opacities.size(); ++i) {
                                const auto& previous =
                                    switch_trace->frame_opacities.at(i - 1);
                                const auto& current =
                                    switch_trace->frame_opacities.at(i);
                                if (std::abs(current.first - previous.first) > 0.002
                                    || std::abs(current.second - previous.second) > 0.002)
                                    ++transition_samples;
                            }
                            const double content_drift =
                                switch_trace->max_content_y
                                - switch_trace->min_content_y;
                            int motion_samples = 0;
                            int direction_reversals = 0;
                            int direction = 0;
                            for (qsizetype i = 1;
                                 i < switch_trace->content_positions.size(); ++i) {
                                const double step = switch_trace->content_positions.at(i)
                                    - switch_trace->content_positions.at(i - 1);
                                if (std::abs(step) <= 0.01) continue;
                                ++motion_samples;
                                const int next_direction = step > 0.0 ? 1 : -1;
                                if (direction != 0 && next_direction != direction)
                                    ++direction_reversals;
                                direction = next_direction;
                            }
                            const bool pass = final_index
                                    == switch_trace->target_index
                                && content_drift > 20.0 && motion_samples >= 8
                                && direction_reversals == 0
                                && transition_samples >= 2;
                            std::fprintf(
                                stderr,
                                "waywallen detail switch: phase=end final_index=%d "
                                "content_y=%.3f drift=%.3f opacity_samples=%lld "
                                "transition_samples=%d motion_samples=%d "
                                "direction_reversals=%d result=%s\n",
                                final_index,
                                final_grid
                                    ? final_grid->property("contentY").toDouble()
                                    : 0.0,
                                content_drift,
                                static_cast<long long>(
                                    switch_trace->frame_opacities.size()),
                                transition_samples, motion_samples,
                                direction_reversals, pass ? "PASS" : "FAIL");
                            std::fflush(stderr);
                        });
                    });
                }

                if (qEnvironmentVariableIsSet(
                        "WAYWALLEN_VISUAL_CHECK_CLOSE_DETAIL")) {
                    const int close_delay_ms = qEnvironmentVariableIsSet(
                        "WAYWALLEN_VISUAL_CHECK_SWITCH_DETAIL") ? 900 : 360;
                    QTimer::singleShot(
                        close_delay_ms, window,
                        [window = QPointer<QQuickWindow>(window)] {
                        if (! window) return;
                        auto* grid = find_visual_item(window->contentItem(),
                                                      u"wallpaperPreviewGrid"_s);
                        auto* panel = find_visual_item(window->contentItem(),
                                                       u"wallpaperDetailPanel"_s);
                        if (! grid || ! panel) return;

                        struct DetailCloseTrace {
                            QPointer<QQuickWindow> window;
                            int selected_index { -1 };
                            QVector<double> content_positions;
                            QVector<double> selected_scene_centers_y;
                            QString capture_dir;
                            QVector<QImage> captures;
                            int sample_index { 0 };
                            QMetaObject::Connection connection;
                        };
                        auto close_trace = std::make_shared<DetailCloseTrace>();
                        close_trace->window = window;
                        close_trace->selected_index =
                            grid->property("currentIndex").toInt();
                        close_trace->capture_dir = qEnvironmentVariable(
                            "WAYWALLEN_VISUAL_CHECK_CLOSE_DETAIL_DIR");
                        if (! close_trace->capture_dir.isEmpty()) {
                            QDir().mkpath(close_trace->capture_dir);
                            close_trace->captures.reserve(48);
                        }
                        const auto sample_close = [close_trace] {
                            if (! close_trace->window) return;
                            auto* sampled_grid = find_visual_item(
                                close_trace->window->contentItem(),
                                u"wallpaperPreviewGrid"_s);
                            if (sampled_grid) {
                                close_trace->content_positions.push_back(
                                    sampled_grid->property("contentY").toDouble());
                                auto* current_item = qobject_cast<QQuickItem*>(
                                    sampled_grid->property("currentItem")
                                        .value<QObject*>());
                                auto* surface = find_visual_item(
                                    current_item, u"wallpaperCardSurface"_s);
                                if (surface) {
                                    const auto center = surface->mapToScene(QPointF {
                                        surface->width() / 2.0,
                                        surface->height() / 2.0,
                                    });
                                    close_trace->selected_scene_centers_y.push_back(
                                        center.y());
                                }
                            }
                            if (! close_trace->capture_dir.isEmpty()
                                && close_trace->sample_index % 2 == 0
                                && close_trace->captures.size() < 48) {
                                const auto image = close_trace->window->grabWindow();
                                if (! image.isNull())
                                    close_trace->captures.push_back(image);
                            }
                            ++close_trace->sample_index;
                        };
                        sample_close();
                        close_trace->connection = QObject::connect(
                            window, &QQuickWindow::afterAnimating, window,
                            sample_close);
                        const bool invoked = QMetaObject::invokeMethod(
                            panel, "back", Qt::DirectConnection);
                        std::fprintf(
                            stderr,
                            "waywallen detail close: phase=start index=%d "
                            "content_y=%.3f invoked=%d\n",
                            close_trace->selected_index,
                            grid->property("contentY").toDouble(),
                            invoked ? 1 : 0);
                        std::fflush(stderr);

                        QTimer::singleShot(620, window,
                                           [close_trace, sample_close, invoked] {
                            if (! close_trace->window) return;
                            QObject::disconnect(close_trace->connection);
                            sample_close();
                            auto* final_grid = find_visual_item(
                                close_trace->window->contentItem(),
                                u"wallpaperPreviewGrid"_s);
                            auto* page = find_visual_item(
                                close_trace->window->contentItem(),
                                u"wallpaperPage"_s);
                            auto* current_item = final_grid
                                ? qobject_cast<QQuickItem*>(
                                    final_grid->property("currentItem")
                                        .value<QObject*>())
                                : nullptr;
                            const double content_y = final_grid
                                ? final_grid->property("contentY").toDouble() : 0.0;
                            const double visible_top = final_grid
                                ? content_y
                                    + final_grid->property("topMargin").toDouble()
                                : 0.0;
                            const double visible_bottom = final_grid
                                ? content_y + final_grid->height()
                                    - final_grid->property("bottomMargin").toDouble()
                                : 0.0;
                            const bool current_visible = current_item
                                && current_item->y() + current_item->height()
                                    > visible_top
                                && current_item->y() < visible_bottom;
                            const double usable_center = final_grid
                                ? (final_grid->property("topMargin").toDouble()
                                   + final_grid->height()
                                   - final_grid->property("bottomMargin").toDouble())
                                    / 2.0
                                : 0.0;
                            const double current_center_error = current_item
                                ? current_item->y() + current_item->height() / 2.0
                                    - content_y - usable_center
                                : 0.0;
                            const double middle_row_tolerance = final_grid
                                ? final_grid->property("cellHeight").toDouble() / 4.0
                                : 0.5;
                            int motion_samples = 0;
                            int direction_reversals = 0;
                            int direction = 0;
                            for (qsizetype i = 1;
                                 i < close_trace->content_positions.size(); ++i) {
                                const double step =
                                    close_trace->content_positions.at(i)
                                    - close_trace->content_positions.at(i - 1);
                                if (std::abs(step) <= 0.01) continue;
                                ++motion_samples;
                                const int next_direction = step > 0.0 ? 1 : -1;
                                if (direction != 0 && next_direction != direction)
                                    ++direction_reversals;
                                direction = next_direction;
                            }
                            const int final_index = final_grid
                                ? final_grid->property("currentIndex").toInt() : -1;
                            const double progress = page
                                ? page->property("detailPanelProgress").toDouble()
                                : 1.0;
                            const bool restore_pending = page
                                && page->property("restoreDetailFocusPending").toBool();
                            const double restore_target = page
                                ? page->property("detailRestoreFocusTargetY").toDouble()
                                : 0.0;
                            const bool restore_accepted = page
                                && page->property("detailRestoreFocusScrollAccepted")
                                       .toBool();
                            const auto [minimum_position, maximum_position] =
                                std::minmax_element(
                                    close_trace->content_positions.cbegin(),
                                    close_trace->content_positions.cend());
                            const auto [minimum_center_y, maximum_center_y] =
                                std::minmax_element(
                                    close_trace->selected_scene_centers_y.cbegin(),
                                    close_trace->selected_scene_centers_y.cend());
                            const double selected_y_drift =
                                minimum_center_y
                                        != close_trace->selected_scene_centers_y.cend()
                                    ? *maximum_center_y - *minimum_center_y : 0.0;
                            const bool pass = invoked
                                && final_index == close_trace->selected_index
                                && progress <= 0.001 && current_visible
                                && std::abs(current_center_error)
                                    <= middle_row_tolerance
                                && restore_accepted && ! restore_pending
                                && selected_y_drift <= 1.0;
                            std::fprintf(
                                stderr,
                                "waywallen detail close: phase=end final_index=%d "
                                "content_y=%.3f progress=%.3f current_visible=%d "
                                "current_y=%.3f center_error=%.3f "
                                "restore_target=%.3f restore_accepted=%d "
                                "range=%.3f..%.3f selected_y_drift=%.3f "
                                "restore_pending=%d motion_samples=%d "
                                "direction_reversals=%d result=%s\n",
                                final_index, content_y, progress,
                                current_visible ? 1 : 0,
                                current_item ? current_item->y() : 0.0,
                                current_center_error,
                                restore_target, restore_accepted ? 1 : 0,
                                minimum_position != close_trace->content_positions.cend()
                                    ? *minimum_position : 0.0,
                                maximum_position != close_trace->content_positions.cend()
                                    ? *maximum_position : 0.0,
                                selected_y_drift,
                                restore_pending ? 1 : 0, motion_samples,
                                direction_reversals, pass ? "PASS" : "FAIL");
                            std::fflush(stderr);
                            for (qsizetype i = 0;
                                 i < close_trace->captures.size(); ++i) {
                                const auto path = QStringLiteral("%1/close-%2.png")
                                    .arg(close_trace->capture_dir)
                                    .arg(i, 3, 10, QLatin1Char('0'));
                                QImageWriter writer(path, "PNG");
                                writer.setCompression(1);
                                writer.write(close_trace->captures.at(i));
                            }
                            if (! close_trace->capture_dir.isEmpty()) {
                                std::fprintf(
                                    stderr,
                                    "waywallen detail close frames: saved=%lld dir=%s\n",
                                    static_cast<long long>(
                                        close_trace->captures.size()),
                                    qPrintable(close_trace->capture_dir));
                                std::fflush(stderr);
                            }
                        });
                    });
                }
            });
        }

        // Leave the page transition, initial model sync, and first thumbnail
        // batch enough time to settle before reading the surface back. Longer
        // opt-in interaction probes can request a later final frame.
        const int requested_output_delay = qEnvironmentVariableIntValue(
            "WAYWALLEN_VISUAL_CHECK_OUTPUT_DELAY_MS");
        const int output_delay = requested_output_delay > 0
            ? requested_output_delay : 3000;
        QTimer::singleShot(output_delay, d->m_main_win.data(),
                           [window = QPointer<QQuickWindow>(d->m_main_win), output] {
            if (! window) return;
            if (auto* grid = find_visual_item(window->contentItem(),
                                              u"wallpaperPreviewGrid"_s)) {
                auto* content = qobject_cast<QQuickItem*>(
                    grid->property("contentItem").value<QObject*>());
                const auto cell_width = grid->property("cellWidth").toDouble();
                const auto cell_height = grid->property("cellHeight").toDouble();
                const auto display_width = grid->property("_displayItemWidth").toDouble();
                const auto display_height = grid->property("_displayItemHeight").toDouble();
                auto* current_item = qobject_cast<QQuickItem*>(
                    grid->property("currentItem").value<QObject*>());
                const auto content_y = grid->property("contentY").toDouble();
                const auto visible_top = content_y + grid->property("topMargin").toDouble();
                const auto visible_bottom = content_y + grid->height()
                    - grid->property("bottomMargin").toDouble();
                const bool current_visible = ! current_item
                    || (current_item->y() + current_item->height() > visible_top
                        && current_item->y() < visible_bottom);
                const bool geometry_valid = std::isfinite(cell_width)
                    && std::isfinite(cell_height) && std::isfinite(display_width)
                    && std::isfinite(display_height) && cell_width > 0.0
                    && cell_height > 0.0 && display_width > 0.0 && display_height > 0.0;
                std::fprintf(stderr,
                             "waywallen visual check: grid count=%d visible=%s "
                             "columns=%d cell=%.1fx%.1f display_item=%.1fx%.1f "
                             "window_dpr=%.3f delegates=%lld geometry_valid=%s "
                             "current_index=%d current_visible=%s\n",
                             grid->property("count").toInt(),
                             grid->isVisible() ? "true" : "false",
                             grid->property("_cols").toInt(), cell_width, cell_height,
                             display_width, display_height,
                             window->devicePixelRatio(),
                             static_cast<long long>(content ? content->childItems().size() : 0),
                             geometry_valid ? "true" : "false",
                             grid->property("currentIndex").toInt(),
                             current_visible ? "true" : "false");
            } else {
                std::fprintf(stderr,
                             "waywallen visual check: wallpaper grid not found\n");
            }
            if (auto* page = find_visual_item(window->contentItem(),
                                              u"wallpaperPage"_s)) {
                std::fprintf(stderr,
                             "waywallen visual check: detail_final progress=%.3f\n",
                             page->property("detailPanelProgress").toDouble());
            }
            const auto image = window->grabWindow();
            const bool saved = ! image.isNull() && image.save(output, "PNG");
            std::fprintf(stderr,
                         "waywallen visual check: output=%s size=%dx%d saved=%s\n",
                         qPrintable(output), image.width(), image.height(),
                         saved ? "true" : "false");
            std::fflush(stderr);
        });
    }

    if (d->m_frosted_glass_available) {
        struct FrostedGlassState {
            QPointer<QQuickWindow> window;
            QPointer<QTimer> settle_timer;
            QRegion applied_region;
            bool has_applied_region { false };
            bool compact { false };
            bool suspended_for_resize { false };
            bool trace { false };
            int compositor_updates { 0 };
        };
        auto frosted = std::make_shared<FrostedGlassState>();
        frosted->window = d->m_main_win;
        frosted->trace = qEnvironmentVariableIsSet("WAYWALLEN_RESIZE_TIMING");

        // Updating KWin's blur protocol property for every Wayland configure
        // forces the compositor to rebuild the effect region while it is also
        // stretching the most recent client buffer.  On NVIDIA that exposed
        // old whole-window frames as trails, including otherwise static
        // sidebar icons.  Cache identical regions and debounce the genuinely
        // size-dependent compact/height cases until the configure burst ends.
        const auto apply_frosted_glass = [frosted](bool force) {
            auto* window = frosted->window.data();
            if (! window) return;

            // KWin treats an empty blur region as the entire window.  Most of
            // the desktop shell is intentionally opaque, so blurring all of
            // it wastes compositor work behind every scrolling thumbnail.
            // Limit the native effect to the actual glass affordance instead.
            constexpr int desktop_sidebar_width = 240;
            // Keep the native KWin region in lockstep with Qcm.Material's
            // WindowClassCompact cutoff. Otherwise the 600--639px range
            // renders a desktop sidebar while KWin only blurs a nonexistent
            // compact bottom bar.
            constexpr int compact_breakpoint = 600;
            // Keep the compositor's behind-window region aligned with the
            // full QML glass field, not merely its shorter navigation row.
            constexpr int compact_bottom_bar_height = 88;
            const bool    compact                   = window->width() < compact_breakpoint;
            const QRegion blur_region =
                compact ? QRegion(0,
                                  qMax(0, window->height() - compact_bottom_bar_height),
                                  qMax(0, window->width()),
                                  qMin(compact_bottom_bar_height, window->height()))
                        : QRegion(0,
                                  0,
                                  qMin(desktop_sidebar_width, window->width()),
                                  qMax(0, window->height()));

            if (! force && frosted->has_applied_region
                && blur_region == frosted->applied_region)
                return;

            KWindowEffects::enableBlurBehind(window, ! blur_region.isEmpty(), blur_region);
            frosted->applied_region = blur_region;
            frosted->has_applied_region = true;
            frosted->compact = compact;
            frosted->suspended_for_resize = false;
            ++frosted->compositor_updates;
            if (frosted->trace) {
                const auto bounds = blur_region.boundingRect();
                std::fprintf(stderr,
                             "waywallen resize blur: update=%d force=%d compact=%d "
                             "region=%d,%d %dx%d window=%dx%d\n",
                             frosted->compositor_updates, force ? 1 : 0,
                             compact ? 1 : 0, bounds.x(), bounds.y(),
                             bounds.width(), bounds.height(), window->width(),
                             window->height());
                std::fflush(stderr);
            }
        };

        // KWin's behind-window blur and Qt Quick's local backdrop effects are
        // both offscreen passes.  Keeping them live while xdg_toplevel resize
        // configures stream in makes KWin repeatedly stretch an older client
        // buffer on NVIDIA, which is visible as duplicate sidebar icons and
        // card trails.  The opaque material tint remains during the gesture;
        // restore the glass once the geometry has been quiet for one short
        // settle interval.
        const auto suspend_frosted_glass = [frosted] {
            auto* window = frosted->window.data();
            if (! window || frosted->suspended_for_resize) return;
            KWindowEffects::enableBlurBehind(window, false, QRegion {});
            frosted->suspended_for_resize = true;
            frosted->has_applied_region = false;
            ++frosted->compositor_updates;
            if (frosted->trace) {
                std::fprintf(stderr,
                             "waywallen resize blur: update=%d suspended=1 window=%dx%d\n",
                             frosted->compositor_updates, window->width(),
                             window->height());
                std::fflush(stderr);
            }
        };

        auto* blur_settle_timer = new QTimer(d->m_main_win);
        frosted->settle_timer = blur_settle_timer;
        blur_settle_timer->setSingleShot(true);
        blur_settle_timer->setInterval(96);
        QObject::connect(blur_settle_timer, &QTimer::timeout, d->m_main_win,
                         [apply_frosted_glass] { apply_frosted_glass(false); });

        d->m_main_win->setColor(Qt::transparent);
        // The glass tints provide contrast themselves. KWin's contrast effect
        // flattens the blurred backdrop on some Wayland themes.
        KWindowEffects::enableBackgroundContrast(d->m_main_win, false);
        apply_frosted_glass(true);
        QObject::connect(
            d->m_main_win, &QWindow::widthChanged, d->m_main_win,
            [frosted, suspend_frosted_glass](int) {
                suspend_frosted_glass();
                if (frosted->settle_timer) frosted->settle_timer->start();
            });
        QObject::connect(
            d->m_main_win, &QWindow::heightChanged, d->m_main_win,
            [frosted, suspend_frosted_glass](int) {
                suspend_frosted_glass();
                if (frosted->settle_timer) frosted->settle_timer->start();
            });
        // Some KWin sessions allocate the Wayland surface just after QML has
        // constructed the window. These two forced startup submissions retain
        // the established reliable blur initialization without affecting live
        // resize.
        QTimer::singleShot(0, d->m_main_win,
                           [apply_frosted_glass] { apply_frosted_glass(true); });
        QTimer::singleShot(80, d->m_main_win,
                           [apply_frosted_glass] { apply_frosted_glass(true); });
    }
}

void App::attachScrollTimingGrid() {
    Q_D(App);
    auto* timing = d->m_scroll_timing.get();
    if (! timing || ! d->m_main_win) return;

    // StackView/Pool keep visual ownership separately from QObject parentage,
    // so a QObject::findChild() can miss the active page. Traverse the Quick
    // tree and bind to whichever cached page is effectively visible.
    QQuickItem* grid { nullptr };
    QString grid_name;
    const std::array candidates {
        std::pair { u"wallpaperPreviewGrid"_s, u"wallpaper"_s },
        std::pair { u"discoverPreviewGrid"_s, u"discover"_s },
        std::pair { u"statusScrollView"_s, u"status"_s },
    };
    for (const auto& [object_name, name] : candidates) {
        auto* candidate = find_visual_item(d->m_main_win->contentItem(), object_name);
        if (! candidate || ! candidate->isVisible()) continue;
        grid = candidate;
        grid_name = name;
        break;
    }
    if (! grid) return;
    if (timing->grid == grid) return;

    const auto* meta          = grid->metaObject();
    const bool  has_content_y = meta->indexOfSignal("contentYChanged()") >= 0;
    const bool  has_moving    = meta->indexOfSignal("movingChanged()") >= 0;
    if (! has_content_y || ! has_moving) {
        std::fprintf(stderr,
                     "waywallen scroll timing: grid=%s has no Flickable timing signals\n",
                     qPrintable(grid_name));
        std::fflush(stderr);
        return;
    }

    if (timing->content_connection)
        QObject::disconnect(timing->content_connection);
    if (timing->moving_connection)
        QObject::disconnect(timing->moving_connection);
    timing->active = false;
    timing->grid = grid;
    timing->grid_name = grid_name;
    timing->content_connection = QObject::connect(
        grid, SIGNAL(contentYChanged()), this, SLOT(onScrollTimingContentYChanged()));
    timing->moving_connection = QObject::connect(
        grid, SIGNAL(movingChanged()), this, SLOT(onScrollTimingMovementChanged()));
    std::fprintf(stderr, "waywallen scroll timing: attached grid=%s object=%s\n",
                 qPrintable(grid_name), qPrintable(grid->objectName()));
    std::fflush(stderr);
}

void App::onScrollTimingContentYChanged() {
    Q_D(App);
    if (auto* timing = d->m_scroll_timing.get()) timing->onContentYChanged();
}

void App::onScrollTimingMovementChanged() {
    Q_D(App);
    if (auto* timing = d->m_scroll_timing.get()) timing->onMovementChanged();
}

auto App::engine() const -> QQmlApplicationEngine* {
    Q_D(const App);
    return d->m_qml_engine.as_mut_ptr();
}

auto App::backend() const -> Backend* {
    Q_D(const App);
    return d->m_backend.as_mut_ptr();
}

auto App::displayManager() const -> DisplayManager* {
    Q_D(const App);
    return d->m_display_mgr.as_mut_ptr();
}

auto App::rendererManager() const -> RendererManager* {
    Q_D(const App);
    return d->m_renderer_mgr.as_mut_ptr();
}

auto App::libraryManager() const -> LibraryManager* {
    Q_D(const App);
    return d->m_library_mgr.as_mut_ptr();
}

auto App::gpuManager() const -> GpuManager* {
    Q_D(const App);
    return d->m_gpu_mgr.as_mut_ptr();
}

auto App::networkCacheSize() const -> qint64 {
    Q_D(const App);
    return d->m_network_cache_size;
}

auto App::networkCacheMaximumSize() const -> qint64 {
    Q_D(const App);
    return d->m_qml_network_cache.maximumCacheSize();
}

auto App::uiLanguage() const -> const QString& {
    Q_D(const App);
    return d->m_ui_language->preference();
}

auto App::resolvedUiLanguage() const -> const QString& {
    Q_D(const App);
    return d->m_ui_language->resolvedLanguage();
}

auto App::availableUiLanguages() const -> QVariantList {
    Q_D(const App);
    return d->m_ui_language->availableLanguages();
}

auto App::frostedGlassAvailable() const -> bool {
    Q_D(const App);
    return d->m_frosted_glass_available;
}

void App::refreshNetworkCacheSize() {
    Q_D(App);
    const auto size = d->m_qml_network_cache.cacheSize();
    if (d->m_network_cache_size == size) return;
    d->m_network_cache_size = size;
    Q_EMIT networkCacheSizeChanged();
}

void App::setNetworkCacheMaximumSize(qint64 size) {
    Q_D(App);
    if (size <= 0 || d->m_qml_network_cache.maximumCacheSize() == size) return;
    d->m_qml_network_cache.setMaximumCacheSize(size);
    Q_EMIT networkCacheMaximumSizeChanged();
    refreshNetworkCacheSize();
}

void App::clearNetworkCache() {
    Q_D(App);
    d->m_qml_network_cache.clear();
    refreshNetworkCacheSize();
}

bool App::setUiLanguage(const QString& language) {
    Q_D(App);
    const auto previous_preference = d->m_ui_language->preference();
    const auto previous_resolved   = d->m_ui_language->resolvedLanguage();
    if (! d->m_ui_language->setLanguage(language)) return false;

    if (previous_preference != d->m_ui_language->preference()) Q_EMIT uiLanguageChanged();
    if (previous_resolved != d->m_ui_language->resolvedLanguage())
        Q_EMIT resolvedUiLanguageChanged();
    return true;
}

bool App::eventFilter(QObject* watched, QEvent* event) {
    if (event->type() == QEvent::LocaleChange) {
        Q_D(App);
        const auto previous_resolved = d->m_ui_language->resolvedLanguage();
        if (d->m_ui_language->preference() == QStringLiteral("system") &&
            d->m_ui_language->refreshSystemLanguage()) {
            Q_EMIT uiLanguageChanged();
            if (previous_resolved != d->m_ui_language->resolvedLanguage())
                Q_EMIT resolvedUiLanguageChanged();
        }
    }

    // The application filter already exists for locale changes.  Keep wheel
    // observation entirely dormant unless the opt-in probe was constructed,
    // and only accept events over the active wallpaper grid.
    if (event->type() == QEvent::Wheel) {
        Q_D(App);
        auto* timing = d->m_scroll_timing.get();
        if (timing && watched == d->m_main_win.data() && timing->grid) {
            const auto* wheel = static_cast<const QWheelEvent*>(event);
            const bool  vertical_delta =
                wheel->pixelDelta().y() != 0 || wheel->angleDelta().y() != 0;
            auto* grid_item = qobject_cast<QQuickItem*>(timing->grid.data());
            if (vertical_delta && grid_item && grid_item->isVisible() &&
                grid_item->contains(grid_item->mapFromScene(wheel->position()))) {
                timing->onWheel(*wheel);
            }
        }
    }
    return QObject::eventFilter(watched, event);
}

void App::load_settings() {}

void App::save_settings() {}

} // namespace waywallen

#include "waywallen/app.moc.cpp"
