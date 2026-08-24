module;
#include "QExtra/macro_qt.hpp"

#ifdef Q_MOC_RUN
#    include "waywallen/scroll/animator.moc"
#endif

#include <QPointer>

export module waywallen:scroll.animator;
export import qextra;

namespace waywallen
{

/// Accumulates discrete wheel notches into an updateable destination and
/// advances a continuous, velocity-preserving trajectory from Qt Quick's
/// render-synchronized FrameAnimation clock.
export class WheelScrollAnimator : public QObject {
    Q_OBJECT
    QML_ELEMENT

    Q_PROPERTY(QObject* flickable READ flickable WRITE setFlickable NOTIFY flickableChanged FINAL)
    Q_PROPERTY(bool scrolling READ scrolling NOTIFY scrollingChanged FINAL)
    Q_PROPERTY(qreal angularFrequency READ angularFrequency WRITE setAngularFrequency NOTIFY
                   angularFrequencyChanged FINAL)

public:
    explicit WheelScrollAnimator(QObject* parent = nullptr);

    auto flickable() const -> QObject* { return m_flickable.data(); }
    void setFlickable(QObject* flickable);

    auto scrolling() const -> bool { return m_scrolling; }

    auto angularFrequency() const -> qreal { return m_angular_frequency; }
    void setAngularFrequency(qreal frequency);

    Q_INVOKABLE bool scrollBy(qreal delta);
    Q_INVOKABLE bool scrollTo(qreal position);
    Q_INVOKABLE void advance(qreal frameTimeSeconds);
    Q_INVOKABLE void cancel();

Q_SIGNALS:
    void flickableChanged();
    void scrollingChanged();
    void angularFrequencyChanged();

private:
    auto minimumContentY() const -> qreal;
    auto maximumContentY() const -> qreal;
    auto currentContentY() const -> qreal;
    void setContentY(qreal value);
    void stopAt(qreal value);

    QPointer<QObject> m_flickable;
    qreal             m_destination_y { 0.0 };
    qreal             m_velocity_y { 0.0 };
    qreal             m_angular_frequency { 30.0 };
    bool              m_scrolling { false };
};

} // namespace waywallen
