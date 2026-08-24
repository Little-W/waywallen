module;
#include "waywallen/scroll/animator.moc.h"

#include <QMetaObject>
#include <algorithm>
#include <cmath>

module waywallen;

import :scroll.animator;

namespace waywallen
{

namespace
{
constexpr qreal kPositionEpsilon { 0.04 };
constexpr qreal kVelocityEpsilon { 0.8 };
}

WheelScrollAnimator::WheelScrollAnimator(QObject* parent): QObject(parent) {}

void WheelScrollAnimator::setFlickable(QObject* flickable) {
    if (m_flickable == flickable) return;
    cancel();
    m_flickable = flickable;
    if (m_flickable) {
        QObject::connect(m_flickable, &QObject::destroyed, this, [this] {
            cancel();
            m_flickable = nullptr;
            Q_EMIT flickableChanged();
        });
        m_destination_y = currentContentY();
    }
    Q_EMIT flickableChanged();
}

void WheelScrollAnimator::setAngularFrequency(qreal frequency) {
    frequency = std::clamp(frequency, 8.0, 80.0);
    if (qFuzzyCompare(m_angular_frequency, frequency)) return;
    m_angular_frequency = frequency;
    Q_EMIT angularFrequencyChanged();
}

auto WheelScrollAnimator::minimumContentY() const -> qreal {
    if (! m_flickable) return 0.0;
    return m_flickable->property("originY").toReal()
        - m_flickable->property("topMargin").toReal();
}

auto WheelScrollAnimator::maximumContentY() const -> qreal {
    if (! m_flickable) return 0.0;
    const auto minimum = minimumContentY();
    // Flickable's lower extent uses bottomMargin.  Using topMargin here made
    // the destination 52 px beyond WallpaperPage's real lower bound
    // (60 px top bar versus 8 px bottom inset). Flickable clamped every write
    // back to its true bound while this animator kept chasing the unreachable
    // value forever, so `scrolling` never became false and a later ScrollBar
    // drag was pulled back to the stale bottom destination.
    return std::max(
        minimum,
        m_flickable->property("contentHeight").toReal()
            + m_flickable->property("originY").toReal()
            - m_flickable->property("height").toReal()
            + m_flickable->property("bottomMargin").toReal());
}

auto WheelScrollAnimator::currentContentY() const -> qreal {
    return m_flickable ? m_flickable->property("contentY").toReal() : 0.0;
}

void WheelScrollAnimator::setContentY(qreal value) {
    if (! m_flickable) return;
    m_flickable->setProperty("contentY", value);
}

auto WheelScrollAnimator::scrollBy(qreal delta) -> bool {
    if (! m_flickable || ! std::isfinite(delta)) return false;
    const auto minimum = minimumContentY();
    const auto maximum = maximumContentY();
    if (maximum <= minimum) return false;

    const auto base = m_scrolling ? m_destination_y : currentContentY();
    return scrollTo(base + delta);
}

auto WheelScrollAnimator::scrollTo(qreal position) -> bool {
    if (! m_flickable || ! std::isfinite(position)) return false;
    const auto minimum = minimumContentY();
    const auto maximum = maximumContentY();
    if (maximum <= minimum) return false;

    const auto next = std::clamp(position, minimum, maximum);
    if (std::abs(next - currentContentY()) < kPositionEpsilon
        && std::abs(next - m_destination_y) < kPositionEpsilon)
        return false;

    // Match browser compositor scrolling: new wheel input updates the target
    // of the in-flight curve; it does not restart easing or discard velocity.
    QMetaObject::invokeMethod(m_flickable, "cancelFlick", Qt::DirectConnection);
    m_destination_y = next;
    if (! m_scrolling) {
        m_velocity_y = 0.0;
        m_scrolling = true;
        Q_EMIT scrollingChanged();
    }
    return true;
}

void WheelScrollAnimator::cancel() {
    const bool was_scrolling = m_scrolling;
    m_scrolling = false;
    m_velocity_y = 0.0;
    m_destination_y = currentContentY();
    if (was_scrolling) Q_EMIT scrollingChanged();
}

void WheelScrollAnimator::stopAt(qreal value) {
    setContentY(value);
    m_velocity_y = 0.0;
    m_destination_y = value;
    const bool was_scrolling = m_scrolling;
    m_scrolling = false;
    if (was_scrolling) Q_EMIT scrollingChanged();
}

void WheelScrollAnimator::advance(qreal frameTimeSeconds) {
    if (! m_scrolling) return;
    if (! m_flickable) {
        cancel();
        return;
    }

    const auto minimum = minimumContentY();
    const auto maximum = maximumContentY();
    m_destination_y = std::clamp(m_destination_y, minimum, maximum);

    if (! std::isfinite(frameTimeSeconds) || frameTimeSeconds <= 0.0) return;
    // The scene graph supplies real elapsed time for the frame.  Cap a long
    // suspend/resume gap so one delayed frame cannot jump across the list.
    const qreal dt = std::clamp(frameTimeSeconds, 0.001, 0.025);
    const qreal current = currentContentY();
    const qreal error = current - m_destination_y;
    const qreal omega = m_angular_frequency;
    const qreal c = m_velocity_y + omega * error;
    const qreal decay = std::exp(-omega * dt);
    const qreal next_error = (error + c * dt) * decay;
    m_velocity_y = (m_velocity_y - omega * c * dt) * decay;
    const qreal next = std::clamp(m_destination_y + next_error, minimum, maximum);
    setContentY(next);

    if (std::abs(next_error) < kPositionEpsilon
        && std::abs(m_velocity_y) < kVelocityEpsilon)
        stopAt(m_destination_y);
}

} // namespace waywallen

#include "waywallen/scroll/animator.moc.cpp"
