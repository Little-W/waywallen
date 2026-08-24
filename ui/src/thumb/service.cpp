module;
#include "waywallen/thumb/service.moc.h"

#include <QtGui/qrgb.h>
#include <QtNetwork/QNetworkReply>
#include <QtNetwork/QNetworkRequest>
#include <algorithm>
#include <utility>

module waywallen;

import :thumb.service;
import rstd.cppstd;
import wavsen.decode;

using namespace Qt::Literals::StringLiterals;

namespace waywallen
{

namespace
{

constexpr int kLargeMaxEdge  = 256;
constexpr int kXLargeMaxEdge = 512;
constexpr int kMaxThreads    = 4;
constexpr auto kCacheRepresentation = "waywallen-thumbnail-v3";
constexpr int  kAnimatedPosterProbeFrames = 12;

auto is_animated_remote_type(QString content_type, QString disposition) -> bool {
    content_type = content_type.trimmed().toLower();
    disposition = disposition.toLower();
    return content_type == u"image/gif"_s
        || content_type == u"image/apng"_s
        || content_type == u"image/vnd.mozilla.apng"_s
        || content_type == u"image/mng"_s
        || content_type == u"image/webp"_s
        || disposition.contains(u".gif"_s)
        || disposition.contains(u".apng"_s)
        || disposition.contains(u".mng"_s)
        || disposition.contains(u".webp"_s);
}

auto thumb_root() -> QString {
    if (auto v = qEnvironmentVariable("WAYWALLEN_THUMB_DIR"); ! v.isEmpty()) {
        return v;
    }
    if (auto v = qEnvironmentVariable("XDG_CACHE_HOME"); ! v.isEmpty()) {
        return v + u"/thumbnails"_s;
    }
    return QDir::homePath() + u"/.cache/thumbnails"_s;
}

void ensure_dir(const QString& path, QFile::Permissions perms) {
    QDir().mkpath(path);
    QFile(path).setPermissions(perms);
}

auto normalize_thumbnail_edge(int edge) -> int {
    // Two tiers are deliberate: 256 px matches dense wallpaper grids, while
    // detail/video surfaces keep the historic 512 px quality.  Normalizing
    // also makes the cache directory part of the representation key.
    return edge <= kLargeMaxEdge ? kLargeMaxEdge : kXLargeMaxEdge;
}

auto large_thumbnail_cache_dir() -> const QString& {
    // Resolving a cold poster cache can happen once per new grid delegate.
    // Directory creation/permission changes are filesystem syscalls and need
    // to be paid once, not in every GUI-thread cache-key lookup.
    static const QString large = [] {
        const QString            root = thumb_root();
        const QString            dir  = root + u"/large"_s;
        const QFile::Permissions dir_perms { QFile::ReadOwner, QFile::WriteOwner, QFile::ExeOwner };
        ensure_dir(root, dir_perms);
        ensure_dir(dir, dir_perms);
        return dir;
    }();
    return large;
}

auto xlarge_thumbnail_cache_dir() -> const QString& {
    static const QString xlarge = [] {
        const QString            root = thumb_root();
        const QString            dir  = root + u"/x-large"_s;
        const QFile::Permissions dir_perms { QFile::ReadOwner, QFile::WriteOwner, QFile::ExeOwner };
        ensure_dir(root, dir_perms);
        ensure_dir(dir, dir_perms);
        return dir;
    }();
    return xlarge;
}

auto thumbnail_cache_dir(int max_edge) -> const QString& {
    return max_edge <= kLargeMaxEdge ? large_thumbnail_cache_dir() : xlarge_thumbnail_cache_dir();
}

auto compute_cache_stem(const QString& abs_path, int max_edge) -> QString {
    const QString& sub = thumbnail_cache_dir(max_edge);

    const QString    uri = u"file://"_s + abs_path;
    // Salt the representation key when the poster algorithm changes. Older
    // caches stored frame 0 verbatim, which leaves animated previews whose
    // first frame is blank permanently black while paused.
    QByteArray representation = uri.toUtf8();
    representation += '\n';
    representation += kCacheRepresentation;
    const QByteArray h = QCryptographicHash::hash(representation, QCryptographicHash::Md5).toHex();
    return sub + u"/"_s + QString::fromLatin1(h);
}

auto frame_cache_path(const QString& cache_stem, bool first_frame_blank) -> QString {
    // The suffix makes the poster decision persistent without opening every
    // PNG on the GUI thread. Two stat calls preserve the hot-cache fast path
    // while QML receives enough information to skip an empty animation lead.
    return cache_stem
        + (first_frame_blank ? u"-skip-first.png"_s : u"-frame-zero.png"_s);
}

auto is_effectively_blank(const QImage& image) -> bool {
    if (image.isNull()) return true;

    // A small nearest-neighbour probe is sufficient to distinguish an empty
    // transparent/black lead frame from a deliberately dark picture. Avoid a
    // full-resolution conversion in the thumbnail worker.
    const QImage probe = image.scaled(
                                  32, 32, Qt::IgnoreAspectRatio, Qt::FastTransformation)
                             .convertToFormat(QImage::Format_ARGB32);
    int visible_samples = 0;
    int content_samples = 0;
    for (int y = 0; y < probe.height(); ++y) {
        const auto* line = reinterpret_cast<const QRgb*>(probe.constScanLine(y));
        for (int x = 0; x < probe.width(); ++x) {
            const QRgb pixel = line[x];
            if (qAlpha(pixel) <= 16) continue;
            ++visible_samples;
            if (std::max({ qRed(pixel), qGreen(pixel), qBlue(pixel) }) > 12)
                ++content_samples;
        }
    }
    return visible_samples == 0
           || content_samples * 100 < visible_samples;
}

struct RepresentativeImage {
    QImage image;
    bool   first_frame_blank { false };
};

auto read_representative_image(QImageReader& reader, QString& error)
    -> RepresentativeImage {
    QImage image = reader.read();
    if (image.isNull()) {
        error = reader.errorString();
        return {};
    }
    const bool first_frame_blank = reader.supportsAnimation()
        && is_effectively_blank(image);
    if (! first_frame_blank) return { std::move(image), false };

    // Repeated read() calls return successive frames for animated formats.
    // Probe only the beginning so a malformed or very long animation cannot
    // monopolize a thumbnail worker. Keep frame 0 as a last-resort fallback.
    const QImage first = image;
    for (int frame = 1; frame < kAnimatedPosterProbeFrames && reader.canRead(); ++frame) {
        image = reader.read();
        if (image.isNull()) break;
        if (! is_effectively_blank(image))
            return { std::move(image), true };
    }
    return { first, true };
}

auto fit_inside(QSize src, std::uint32_t max_edge) -> QSize {
    if (src.width() <= 0 || src.height() <= 0) return QSize();
    const int me = static_cast<int>(max_edge);
    if (src.width() <= me && src.height() <= me) return src;
    if (src.width() >= src.height()) {
        return QSize(me, std::max(1, src.height() * me / src.width()));
    }
    return QSize(std::max(1, src.width() * me / src.height()), me);
}

bool write_thumb_png(const QImage& img, const QString& cache_path, const QString& uri,
                     qint64 src_mtime, qint64 src_size, QString& err_out) {
    // The UI only creates the cache directory once.  Recreate it here on the
    // worker thread if a cache cleaner removed it while the application was
    // running, rather than turning a normal miss into a permanent failure.
    const QString            cache_dir = QFileInfo(cache_path).absolutePath();
    const QFile::Permissions dir_perms { QFile::ReadOwner, QFile::WriteOwner, QFile::ExeOwner };
    if (! QDir(cache_dir).exists()) ensure_dir(cache_dir, dir_perms);

    QImage tagged = img;
    tagged.setText(u"Thumb::URI"_s, uri);
    tagged.setText(u"Thumb::MTime"_s, QString::number(src_mtime));
    tagged.setText(u"Thumb::Size"_s, QString::number(src_size));

    const auto    rnd = QRandomGenerator::system()->generate();
    const QString tmp = cache_path + u".tmp."_s +
                        QString::number(QCoreApplication::applicationPid()) + u"."_s +
                        QString::number(rnd, 16);

    QImageWriter w(tmp, "png");
    if (! w.write(tagged)) {
        err_out = w.errorString();
        QFile::remove(tmp);
        return false;
    }
    QFile(tmp).setPermissions(QFile::Permissions { QFile::ReadOwner, QFile::WriteOwner });

    // Replace atomically. QFile::rename does not overwrite on POSIX, so
    // remove the destination first if it exists.
    if (QFile::exists(cache_path)) QFile::remove(cache_path);
    if (! QFile::rename(tmp, cache_path)) {
        err_out = u"rename failed: "_s + tmp + u" -> "_s + cache_path;
        QFile::remove(tmp);
        return false;
    }
    return true;
}

} // namespace

// ---------------------------------------------------------------------------
// ThumbnailJob
// ---------------------------------------------------------------------------

ThumbnailJob::ThumbnailJob(QString pending_key, QString job_path, QString cache_path, bool is_video,
                           int max_edge, qint64 src_mtime, qint64 src_size)
    : QObject(nullptr),
      QRunnable(),
      m_pending_key(std::move(pending_key)),
      m_job_path(std::move(job_path)),
      m_cache_path(std::move(cache_path)),
      m_is_video(is_video),
      m_max_edge(max_edge),
      m_src_mtime(src_mtime),
      m_src_size(src_size) {
    // Manage lifetime via deleteLater() on the owning thread; never
    // let QThreadPool `delete this` from a worker thread on a QObject.
    setAutoDelete(false);
}

void ThumbnailJob::run() {
    QImage  img;
    bool    first_frame_blank { false };
    QString error;

    if (m_is_video) {
        wavsen::decode::ThumbOptions opts;
        opts.max_edge = rstd::u32(static_cast<std::uint32_t>(m_max_edge));
        auto path     = m_job_path.toStdString();
        auto path_ref = rstd::move(rstd::cppstd::as_str(path)).unwrap();
        auto res      = wavsen::decode::extract_thumbnail(path_ref, opts);
        if (res.is_err()) {
            auto failure = rstd::move(res).unwrap_err();
            error        = QString::fromStdString(rstd::cppstd::to_string(failure.message));
        } else {
            auto rgba = std::move(res).unwrap();
            img       = QImage(rgba.data.data(),
                               static_cast<int>(rgba.width.to_primitive()),
                               static_cast<int>(rgba.height.to_primitive()),
                               static_cast<int>(rgba.stride.to_primitive()),
                               QImage::Format_RGBA8888)
                            .copy();
        }
    } else {
        QImageReader reader(m_job_path);
        reader.setAutoTransform(true);
        const QSize target = fit_inside(reader.size(), static_cast<std::uint32_t>(m_max_edge));
        if (target.isValid() && ! target.isEmpty()) {
            reader.setScaledSize(target);
        }
        auto representative = read_representative_image(reader, error);
        img = std::move(representative.image);
        first_frame_blank = representative.first_frame_blank;
    }

    int     out_state = ThumbnailRequest::Failed;
    QString out_path;
    if (! img.isNull()) {
        const QString uri = u"file://"_s + m_job_path;
        const QString cache_path = frame_cache_path(m_cache_path, first_frame_blank);
        QString       werr;
        if (write_thumb_png(img, cache_path, uri, m_src_mtime, m_src_size, werr)) {
            out_state = ThumbnailRequest::Ready;
            out_path  = cache_path;
        } else {
            error = werr;
        }
    }

    Q_EMIT finished(m_pending_key, out_state, out_path, first_frame_blank, error);
}

// ---------------------------------------------------------------------------
// ThumbnailService
// ---------------------------------------------------------------------------

ThumbnailService::ThumbnailService(QObject* parent): QObject(parent) {
    m_pool.setMaxThreadCount(std::min(QThread::idealThreadCount(), kMaxThreads));
}

auto ThumbnailService::instance() -> ThumbnailService* {
    // QPointer auto-nulls when qApp tears down its child tree. Without
    // this, late-destroyed ThumbnailRequests would chase a dangling
    // pointer here and crash inside cancel() iterating freed m_pending.
    static QPointer<ThumbnailService> the = new ThumbnailService(QCoreApplication::instance());
    return the.data();
}

auto ThumbnailService::create(QQmlEngine*, QJSEngine*) -> ThumbnailService* {
    auto* s = instance();
    QJSEngine::setObjectOwnership(s, QJSEngine::CppOwnership);
    return s;
}

void ThumbnailService::submit(ThumbnailRequest* req, const QString& job_path,
                              const QString& cache_path, bool is_video, int max_edge,
                              qint64 src_mtime, qint64 src_size) {
    if (! req) return;
    // The same input can legitimately be requested at two resolutions by a
    // grid and a detail page.  Coalesce only identical cache representations.
    const QString pending_key = cache_path;
    auto          it          = m_pending.find(pending_key);
    if (it == m_pending.end()) {
        Pending p;
        p.key        = pending_key;
        p.cache_path = cache_path;
        p.subscribers.append(QPointer<ThumbnailRequest>(req));
        m_pending.insert(pending_key, std::move(p));

        auto* job = new ThumbnailJob(
            pending_key, job_path, cache_path, is_video, max_edge, src_mtime, src_size);
        connect(job,
                &ThumbnailJob::finished,
                this,
                &ThumbnailService::onJobFinished,
                Qt::QueuedConnection);
        connect(job, &ThumbnailJob::finished, job, &QObject::deleteLater);
        m_pool.start(job);
    } else {
        it->subscribers.append(QPointer<ThumbnailRequest>(req));
    }
}

void ThumbnailService::cancel(ThumbnailRequest* req) {
    if (! req) return;
    QPointer<ThumbnailRequest> rp(req);
    for (auto& p : m_pending) {
        p.subscribers.removeAll(rp);
    }
}

void ThumbnailService::probeRemoteType(ThumbnailRequest* req, const QString& source) {
    if (! req || source.isEmpty()) return;
    if (const auto cached = m_remote_type_cache.constFind(source);
        cached != m_remote_type_cache.cend()) {
        req->_applyRemoteType(source, true, cached.value());
        return;
    }

    auto pending = m_remote_type_pending.find(source);
    if (pending != m_remote_type_pending.end()) {
        const QPointer<ThumbnailRequest> subscriber(req);
        if (! pending->subscribers.contains(subscriber))
            pending->subscribers.append(subscriber);
        return;
    }

    QNetworkRequest request { QUrl(source) };
    request.setAttribute(QNetworkRequest::RedirectPolicyAttribute,
                         QNetworkRequest::NoLessSafeRedirectPolicy);
    auto* reply = m_network.head(request);
    RemoteTypePending entry;
    entry.subscribers.append(QPointer<ThumbnailRequest>(req));
    entry.reply = reply;
    m_remote_type_pending.insert(source, std::move(entry));

    connect(reply, &QNetworkReply::finished, this, [this, source, reply] {
        auto pending = m_remote_type_pending.find(source);
        if (pending == m_remote_type_pending.end()) {
            reply->deleteLater();
            return;
        }
        auto subscribers = std::move(pending->subscribers);
        m_remote_type_pending.erase(pending);

        const bool resolved = reply->error() == QNetworkReply::NoError;
        const auto content_type =
            reply->header(QNetworkRequest::ContentTypeHeader).toString();
        const auto disposition =
            QString::fromUtf8(reply->rawHeader("Content-Disposition"));
        const bool animated = resolved
            && is_animated_remote_type(content_type, disposition);
        if (resolved) {
            // Discover can expose thousands of entries over a long session;
            // keep the process-local classification cache bounded.
            if (m_remote_type_cache.size() >= 2048)
                m_remote_type_cache.clear();
            m_remote_type_cache.insert(source, animated);
        }
        for (auto& subscriber : subscribers) {
            if (subscriber)
                subscriber->_applyRemoteType(source, resolved, animated);
        }
        reply->deleteLater();
    });
}

void ThumbnailService::cancelRemoteTypeProbe(ThumbnailRequest* req) {
    if (! req) return;
    const QPointer<ThumbnailRequest> subscriber(req);
    for (auto& pending : m_remote_type_pending)
        pending.subscribers.removeAll(subscriber);
}

void ThumbnailService::onJobFinished(const QString& key, int state, const QString& cache_path,
                                     bool first_frame_blank, const QString& error) {
    auto it = m_pending.find(key);
    if (it == m_pending.end()) return;
    auto subs = std::move(it->subscribers);
    m_pending.erase(it);

    const QUrl cache_url = cache_path.isEmpty() ? QUrl() : QUrl::fromLocalFile(cache_path);
    for (auto& wp : subs) {
        if (auto* r = wp.data()) {
            r->_applyResult(static_cast<ThumbnailRequest::State>(state), cache_url,
                            first_frame_blank, error);
        }
    }
}

// ---------------------------------------------------------------------------
// ThumbnailRequest
// ---------------------------------------------------------------------------

ThumbnailRequest::ThumbnailRequest(QObject* parent): QObject(parent) {}

ThumbnailRequest::~ThumbnailRequest() {
    if (auto* svc = ThumbnailService::instance()) {
        svc->cancel(this);
        svc->cancelRemoteTypeProbe(this);
    }
}

void ThumbnailRequest::classBegin() {}

void ThumbnailRequest::componentComplete() {
    m_component_complete = true;
    // Wire up "re-submit on input change" only after QML's initial
    // property cascade is done. Until this point, setters merely emit
    // their *Changed signals and the lack of any subscriber keeps
    // scheduleSubmit from firing N times.
    connect(this, &ThumbnailRequest::sourceChanged, this, &ThumbnailRequest::scheduleSubmit);
    connect(this, &ThumbnailRequest::resourceChanged, this, &ThumbnailRequest::scheduleSubmit);
    connect(this, &ThumbnailRequest::wpTypeChanged, this, &ThumbnailRequest::scheduleSubmit);
    connect(this, &ThumbnailRequest::maximumEdgeChanged, this, &ThumbnailRequest::scheduleSubmit);

    scheduleRemoteTypeProbe();

    // Initial resolve — try the synchronous fast path first; if the
    // cache is hot we never enter the service at all.
    ResolvedJob rj;
    if (tryResolveSync(rj)) return;

    auto* svc = ThumbnailService::instance();
    if (! svc) return;
    setCachePathInternal(QUrl());
    setFirstFrameBlankInternal(false);
    setErrorInternal(QString());
    setStateInternal(Loading);
    svc->submit(
        this, rj.job_path, rj.cache_path, rj.is_video, rj.max_edge, rj.src_mtime, rj.src_size);
}

void ThumbnailRequest::setSource(const QString& v) {
    if (m_source == v) return;
    m_source = v;
    Q_EMIT sourceChanged();
}

void ThumbnailRequest::setResource(const QString& v) {
    if (m_resource == v) return;
    m_resource = v;
    Q_EMIT resourceChanged();
}

void ThumbnailRequest::setWpType(const QString& v) {
    if (m_wp_type == v) return;
    m_wp_type = v;
    Q_EMIT wpTypeChanged();
}

void ThumbnailRequest::setRemoteTypeSource(const QString& v) {
    if (m_remote_type_source == v) return;
    if (auto* svc = ThumbnailService::instance())
        svc->cancelRemoteTypeProbe(this);
    m_remote_type_source = v;
    if (m_remote_type_resolved) {
        m_remote_type_resolved = false;
        Q_EMIT remoteTypeResolvedChanged();
    }
    if (m_remote_animated) {
        m_remote_animated = false;
        Q_EMIT remoteAnimatedChanged();
    }
    Q_EMIT remoteTypeSourceChanged();
    if (m_component_complete) scheduleRemoteTypeProbe();
}

void ThumbnailRequest::setMaximumEdge(int v) {
    const int normalized = normalize_thumbnail_edge(v);
    if (m_max_edge == normalized) return;
    m_max_edge = normalized;
    Q_EMIT maximumEdgeChanged();
}

bool ThumbnailRequest::tryResolveSync(ResolvedJob& out) {
    if (! m_source.isEmpty()) {
        out.job_path = QFileInfo(m_source).absoluteFilePath();
        out.is_video = false;
    } else if (! m_resource.isEmpty() && (m_wp_type == u"video"_s || m_wp_type == u"image"_s)) {
        // No preview supplied — generate one from the resource itself.
        // Videos go through the libavformat extractor; images decode
        // via QImageReader (handled in ThumbnailJob::run by is_video).
        out.job_path = QFileInfo(m_resource).absoluteFilePath();
        out.is_video = (m_wp_type == u"video"_s);
    } else {
        setCachePathInternal(QUrl());
        setFirstFrameBlankInternal(false);
        setErrorInternal(u"no preview source"_s);
        setStateInternal(Failed);
        return true;
    }

    QFileInfo fi(out.job_path);
    if (! fi.exists()) {
        setCachePathInternal(QUrl());
        setFirstFrameBlankInternal(false);
        setErrorInternal(u"source file not found"_s);
        setStateInternal(Failed);
        return true;
    }

    out.max_edge          = normalize_thumbnail_edge(m_max_edge);
    out.cache_path        = compute_cache_stem(out.job_path, out.max_edge);
    out.src_mtime         = fi.lastModified().toSecsSinceEpoch();
    out.src_size          = fi.size();
    out.first_frame_blank = false;

    // A stat is much cheaper than opening and parsing the PNG metadata on the
    // GUI thread.  It catches the normal Workshop/package update case while
    // preserving hot-cache lookups for rapid scrolling.
    for (const bool first_frame_blank : { true, false }) {
        const QString candidate = frame_cache_path(out.cache_path, first_frame_blank);
        const QFileInfo cache_info(candidate);
        if (! cache_info.exists()
            || cache_info.lastModified().toSecsSinceEpoch() < out.src_mtime)
            continue;

        out.first_frame_blank = first_frame_blank;
        setErrorInternal(QString());
        setCachePathInternal(QUrl::fromLocalFile(candidate));
        setFirstFrameBlankInternal(first_frame_blank);
        setStateInternal(Ready);
        return true;
    }
    return false;
}

void ThumbnailRequest::scheduleSubmit() {
    auto* svc = ThumbnailService::instance();
    if (! svc) return;
    svc->cancel(this);

    ResolvedJob rj;
    if (tryResolveSync(rj)) return;

    setCachePathInternal(QUrl());
    setFirstFrameBlankInternal(false);
    setErrorInternal(QString());
    setStateInternal(Loading);
    svc->submit(
        this, rj.job_path, rj.cache_path, rj.is_video, rj.max_edge, rj.src_mtime, rj.src_size);
}

void ThumbnailRequest::scheduleRemoteTypeProbe() {
    if (m_remote_type_source.isEmpty()) return;
    if (auto* svc = ThumbnailService::instance())
        svc->probeRemoteType(this, m_remote_type_source);
}

void ThumbnailRequest::_applyResult(State state, QUrl cache_path, bool first_frame_blank,
                                    QString error) {
    setCachePathInternal(cache_path);
    setFirstFrameBlankInternal(state == Ready && first_frame_blank);
    setErrorInternal(error);
    setStateInternal(state);
}

void ThumbnailRequest::_applyRemoteType(QString source, bool resolved, bool animated) {
    if (source != m_remote_type_source) return;
    if (m_remote_animated != animated) {
        m_remote_animated = animated;
        Q_EMIT remoteAnimatedChanged();
    }
    if (m_remote_type_resolved != resolved) {
        m_remote_type_resolved = resolved;
        Q_EMIT remoteTypeResolvedChanged();
    }
}

void ThumbnailRequest::setStateInternal(State s) {
    if (m_state == s) return;
    m_state = s;
    Q_EMIT stateChanged();
}

void ThumbnailRequest::setCachePathInternal(const QUrl& p) {
    if (m_cache_path == p) return;
    m_cache_path = p;
    Q_EMIT cachePathChanged();
}

void ThumbnailRequest::setFirstFrameBlankInternal(bool blank) {
    if (m_first_frame_blank == blank) return;
    m_first_frame_blank = blank;
    Q_EMIT firstFrameBlankChanged();
}

void ThumbnailRequest::setErrorInternal(const QString& e) {
    if (m_error == e) return;
    m_error = e;
    Q_EMIT errorChanged();
}

} // namespace waywallen

#include "waywallen/thumb/service.moc.cpp"
