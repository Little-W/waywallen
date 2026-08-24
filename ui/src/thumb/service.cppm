module;
#include "QExtra/macro_qt.hpp"

#ifdef Q_MOC_RUN
// MOC's preprocessor needs the `Q_DECLARE_INTERFACE` macro for
// `Q_INTERFACES(QQmlParserStatus)` below. The actual compile gets the
// type via `import qextra`, so this only fires under MOC.
#    include "waywallen/thumb/service.moc"
#    include <QtQml/QQmlParserStatus>
#endif
#include <QtNetwork/QNetworkAccessManager>
#include <QtNetwork/QNetworkReply>

export module waywallen:thumb.service;
export import qextra;

namespace waywallen
{

export class ThumbnailRequest;

/// Worker job (module-private). QObject-derived so it can emit a
/// type-safe `finished` signal back to the service via a queued
/// connection — no QPointer + QMetaObject::invokeMethod plumbing.
class ThumbnailJob : public QObject, public QRunnable {
    Q_OBJECT
public:
    ThumbnailJob(QString pending_key, QString job_path, QString cache_path, bool is_video,
                 int max_edge, qint64 src_mtime, qint64 src_size);

    void run() override;

Q_SIGNALS:
    /// Emitted from the worker thread when decoding + cache write
    /// settle. `state` is a `ThumbnailRequest::State` value (`Ready`
    /// or `Failed`); `cache_path` is filled on success, `error` on
    /// failure.
    void finished(const QString& key, int state, const QString& cache_path,
                  bool first_frame_blank, const QString& error);

private:
    QString m_pending_key;
    QString m_job_path;
    QString m_cache_path;
    bool    m_is_video;
    int     m_max_edge;
    qint64  m_src_mtime;
    qint64  m_src_size;
};

/// Background thumbnail generator. Resolves cache hits from
/// `$XDG_CACHE_HOME/thumbnails/{large,x-large}/` per the freedesktop Thumbnail
/// Managing Standard, and dispatches misses to a `QThreadPool` for
/// QImageReader / wavsen::decode decode + atomic PNG write.
///
/// QML-singleton; per-card requests are `ThumbnailRequest` objects that
/// register themselves with the service on each input change.
export class ThumbnailService : public QObject {
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

public:
    static auto instance() -> ThumbnailService*;
    static auto create(QQmlEngine*, QJSEngine*) -> ThumbnailService*;

    /// Submit a cache-miss decode job. The Request resolves cache-hit
    /// and file-not-found cases synchronously before reaching here, so
    /// this entry point only handles the actual worker dispatch.
    void submit(ThumbnailRequest* req, const QString& job_path, const QString& cache_path,
                bool is_video, int max_edge, qint64 src_mtime, qint64 src_size);
    /// Resolve extensionless remote preview media types with one coalesced
    /// HEAD request per URL. This keeps static JPEG cards on the cheap Image
    /// path while allowing GIF/WebP previews to use AnimatedImage.
    void probeRemoteType(ThumbnailRequest* req, const QString& source);
    void cancelRemoteTypeProbe(ThumbnailRequest* req);
    /// Drop any pending subscription for `req` (e.g. on destruction).
    void cancel(ThumbnailRequest* req);

private:
    explicit ThumbnailService(QObject* parent = nullptr);

    struct Pending {
        QString                           key;        // cache path, including size tier
        QString                           cache_path; // resolved thumbnail cache path
        QList<QPointer<ThumbnailRequest>> subscribers;
    };

    struct RemoteTypePending {
        QList<QPointer<ThumbnailRequest>> subscribers;
        QPointer<QNetworkReply>           reply;
    };

    QThreadPool             m_pool;
    QHash<QString, Pending> m_pending; // key = cache path, including size tier
    QNetworkAccessManager                 m_network;
    QHash<QString, bool>                  m_remote_type_cache;
    QHash<QString, RemoteTypePending>     m_remote_type_pending;

    void onJobFinished(const QString& key, int state, const QString& cache_path,
                       bool first_frame_blank, const QString& error);
};

/// Per-card request handle. QML hosts one of these inside
/// `ThumbnailImage.qml`; on `source` / `resource` / `wpType` change it
/// re-submits to `ThumbnailService` and updates `state` / `cachePath`
/// from the worker's result.
///
/// Implements `QQmlParserStatus` so that initial property bindings
/// don't fire one submit per setter — `componentComplete()` runs
/// `scheduleSubmit()` exactly once after all initial properties are
/// settled. Cache-hit and file-not-found cases resolve synchronously
/// without involving the service's thread pool.
export class ThumbnailRequest : public QObject, public QQmlParserStatus {
    Q_OBJECT
    Q_INTERFACES(QQmlParserStatus)
    QML_ELEMENT

    Q_PROPERTY(QString source READ source WRITE setSource NOTIFY sourceChanged FINAL)
    Q_PROPERTY(QString resource READ resource WRITE setResource NOTIFY resourceChanged FINAL)
    Q_PROPERTY(QString wpType READ wpType WRITE setWpType NOTIFY wpTypeChanged FINAL)
    Q_PROPERTY(QString remoteTypeSource READ remoteTypeSource WRITE setRemoteTypeSource
                   NOTIFY remoteTypeSourceChanged FINAL)
    Q_PROPERTY(
        int maximumEdge READ maximumEdge WRITE setMaximumEdge NOTIFY maximumEdgeChanged FINAL)
    Q_PROPERTY(State state READ state NOTIFY stateChanged FINAL)
    Q_PROPERTY(QUrl cachePath READ cachePath NOTIFY cachePathChanged FINAL)
    Q_PROPERTY(bool firstFrameBlank READ firstFrameBlank NOTIFY firstFrameBlankChanged FINAL)
    Q_PROPERTY(bool remoteTypeResolved READ remoteTypeResolved
                   NOTIFY remoteTypeResolvedChanged FINAL)
    Q_PROPERTY(bool remoteAnimated READ remoteAnimated NOTIFY remoteAnimatedChanged FINAL)
    Q_PROPERTY(QString error READ error NOTIFY errorChanged FINAL)

public:
    enum State
    {
        Idle,
        Loading,
        Ready,
        Failed
    };
    Q_ENUM(State)

    explicit ThumbnailRequest(QObject* parent = nullptr);
    ~ThumbnailRequest() override;

    auto source() const -> const QString& { return m_source; }
    void setSource(const QString& v);

    auto resource() const -> const QString& { return m_resource; }
    void setResource(const QString& v);

    auto wpType() const -> const QString& { return m_wp_type; }
    void setWpType(const QString& v);

    auto remoteTypeSource() const -> const QString& { return m_remote_type_source; }
    void setRemoteTypeSource(const QString& v);

    auto maximumEdge() const -> int { return m_max_edge; }
    void setMaximumEdge(int v);

    auto state() const -> State { return m_state; }
    auto cachePath() const -> const QUrl& { return m_cache_path; }
    auto firstFrameBlank() const -> bool { return m_first_frame_blank; }
    auto remoteTypeResolved() const -> bool { return m_remote_type_resolved; }
    auto remoteAnimated() const -> bool { return m_remote_animated; }
    auto error() const -> const QString& { return m_error; }

    // QQmlParserStatus
    void classBegin() override;
    void componentComplete() override;

    // Service callback (gui thread).
    void _applyResult(State state, QUrl cache_path, bool first_frame_blank, QString error);
    void _applyRemoteType(QString source, bool resolved, bool animated);

Q_SIGNALS:
    void sourceChanged();
    void resourceChanged();
    void wpTypeChanged();
    void remoteTypeSourceChanged();
    void maximumEdgeChanged();
    void stateChanged();
    void cachePathChanged();
    void firstFrameBlankChanged();
    void remoteTypeResolvedChanged();
    void remoteAnimatedChanged();
    void errorChanged();

private:
    struct ResolvedJob {
        QString job_path;
        QString cache_path;
        bool    is_video { false };
        bool    first_frame_blank { false };
        int     max_edge { 512 };
        qint64  src_mtime { 0 };
        qint64  src_size { 0 };
    };

    /// Resolve from current properties without touching the thread
    /// pool. Returns true if `state` was driven to Ready or Failed
    /// directly; returns false on a cache miss and fills `out` with
    /// the parameters the caller must hand to the service.
    bool tryResolveSync(ResolvedJob& out);

    void scheduleSubmit();
    void scheduleRemoteTypeProbe();
    void setStateInternal(State s);
    void setCachePathInternal(const QUrl& p);
    void setFirstFrameBlankInternal(bool blank);
    void setErrorInternal(const QString& e);

    QString m_source;
    QString m_resource;
    QString m_wp_type;
    QString m_remote_type_source;
    int     m_max_edge { 512 };
    State   m_state { Idle };
    QUrl    m_cache_path;
    bool    m_first_frame_blank { false };
    bool    m_remote_type_resolved { false };
    bool    m_remote_animated { false };
    bool    m_component_complete { false };
    QString m_error;
};

} // namespace waywallen
