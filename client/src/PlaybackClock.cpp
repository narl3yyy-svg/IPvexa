#include "PlaybackClock.h"

#include <QDateTime>
#include <QQmlEngine>

PlaybackClock *PlaybackClock::instance()
{
    static PlaybackClock *s = new PlaybackClock();
    return s;
}

PlaybackClock *PlaybackClock::create(QQmlEngine *, QJSEngine *)
{
    auto *s = instance();
    QJSEngine::setObjectOwnership(s, QJSEngine::CppOwnership);
    return s;
}

PlaybackClock::PlaybackClock(QObject *parent) : QObject(parent)
{
    m_base = now();
    m_timer.start();
    m_tick.setInterval(50);
    connect(&m_tick, &QTimer::timeout, this, &PlaybackClock::positionChanged);
    m_tick.start();
    // Reverse: jump back speed × interval every interval; tiles show each position.
    m_reverseTimer.setInterval(500);
    connect(&m_reverseTimer, &QTimer::timeout, this, [this]() {
        seek(position() - qint64(500 * speed()));
    });
}

void PlaybackClock::setReverse(bool r)
{
    if (r == m_reverse)
        return;
    m_reverse = r;
    if (r) {
        pause(); // decoders hold the frame at the clock position
        m_reverseTimer.start();
    } else {
        m_reverseTimer.stop();
    }
    emit reverseChanged();
}

void PlaybackClock::stepFrame(int direction, double fps)
{
    setReverse(false);
    pause();
    const qint64 frame = qint64(1000.0 / qBound(1.0, fps, 120.0));
    if (direction < 0) {
        seek(position() - frame);
        return;
    }
    {
        QMutexLocker l(&m_mu);
        m_base += frame;
    }
    emit positionChanged();
}

qint64 PlaybackClock::now() const
{
    return QDateTime::currentMSecsSinceEpoch();
}

qint64 PlaybackClock::positionLocked() const
{
    if (m_live)
        return now();
    if (!m_playing)
        return m_base;
    return m_base + qint64(double(m_timer.elapsed()) * m_speed);
}

qint64 PlaybackClock::position() const
{
    QMutexLocker l(&m_mu);
    return positionLocked();
}

bool PlaybackClock::playing() const
{
    QMutexLocker l(&m_mu);
    return m_playing;
}

double PlaybackClock::speed() const
{
    QMutexLocker l(&m_mu);
    return m_speed;
}

void PlaybackClock::rebase()
{
    m_base = positionLocked();
    m_timer.restart();
}

void PlaybackClock::setSpeed(double s)
{
    s = qBound(0.125, s, 32.0);
    bool crossed;
    {
        QMutexLocker l(&m_mu);
        if (qFuzzyCompare(s, m_speed))
            return;
        rebase();
        crossed = (m_speed > 4.0) != (s > 4.0);
        m_speed = s;
    }
    if (crossed)
        m_gen++; // switch decoders between full-frame and keyframe-only streams
    emit speedChanged();
}

void PlaybackClock::seek(qint64 ms)
{
    const qint64 n = now();
    if (ms >= n - 1000) {
        goLive();
        return;
    }
    bool wasLive;
    {
        QMutexLocker l(&m_mu);
        wasLive = m_live;
        m_live = false;
        m_base = ms;
        m_timer.restart();
    }
    m_gen++;
    if (wasLive)
        emit liveChanged();
    emit seeked();
    emit positionChanged();
}

void PlaybackClock::goLive()
{
    setReverse(false);
    bool changed;
    {
        QMutexLocker l(&m_mu);
        changed = !m_live;
        m_live = true;
        m_playing = true;
        m_speed = 1.0;
    }
    m_gen++;
    if (changed)
        emit liveChanged();
    emit playingChanged();
    emit speedChanged();
    emit positionChanged();
}

void PlaybackClock::play()
{
    setReverse(false);
    {
        QMutexLocker l(&m_mu);
        if (m_playing)
            return;
        m_playing = true;
        m_timer.restart();
    }
    emit playingChanged();
}

void PlaybackClock::pause()
{
    bool wasLive;
    {
        QMutexLocker l(&m_mu);
        if (!m_playing)
            return;
        wasLive = m_live;
        rebase();
        m_live = false; // pausing live freezes the picture: we switch to the recording at "now"
        m_playing = false;
    }
    if (wasLive) {
        m_gen++;
        emit liveChanged();
    }
    emit playingChanged();
}

void PlaybackClock::togglePlay()
{
    if (playing())
        pause();
    else
        play();
}

void PlaybackClock::step(qint64 deltaMs)
{
    seek(position() + deltaMs);
}
