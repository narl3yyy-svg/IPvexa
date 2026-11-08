#pragma once

#include <QObject>
#include <QElapsedTimer>
#include <QMutex>
#include <QTimer>
#include <QtQml/qqmlregistration.h>
#include <atomic>

class QQmlEngine;
class QJSEngine;

// One shared clock for the whole scene: every tile follows it, which is what
// keeps multi-camera playback in sync. Exposed to QML as the `Clock` singleton.
class PlaybackClock : public QObject
{
    Q_OBJECT
    QML_NAMED_ELEMENT(Clock)
    QML_SINGLETON

    Q_PROPERTY(bool live READ live NOTIFY liveChanged)
    Q_PROPERTY(bool playing READ playing NOTIFY playingChanged)
    Q_PROPERTY(double speed READ speed WRITE setSpeed NOTIFY speedChanged)
    Q_PROPERTY(qint64 position READ position NOTIFY positionChanged)
    // Reverse playback: the clock steps backwards and every tile shows the frame at
    // each step (a "rewind scan", like dragging the timeline backwards).
    Q_PROPERTY(bool reverse READ reverse WRITE setReverse NOTIFY reverseChanged)

public:
    static PlaybackClock *instance();
    static PlaybackClock *create(QQmlEngine *, QJSEngine *);

    bool live() const { return m_live; }
    bool playing() const;
    double speed() const;
    void setSpeed(double s);

    // Current position in unix ms. Thread-safe: decoder threads call this.
    qint64 position() const;
    // Bumped on every seek / mode change so decoders know to restart.
    int generation() const { return m_gen.load(); }
    bool fastForward() const { return speed() > 4.0; }
    bool reverse() const { return m_reverse; }
    void setReverse(bool r);

    Q_INVOKABLE void seek(qint64 ms);
    Q_INVOKABLE void goLive();
    Q_INVOKABLE void play();
    Q_INVOKABLE void pause();
    Q_INVOKABLE void togglePlay();
    Q_INVOKABLE void step(qint64 deltaMs);
    // Step one frame while paused. Forward just advances the clock, so decoders show
    // their next frame without restarting; backward seeks.
    Q_INVOKABLE void stepFrame(int direction, double fps);
    Q_INVOKABLE qint64 now() const;

signals:
    void liveChanged();
    void playingChanged();
    void speedChanged();
    void positionChanged();
    void seeked();
    void reverseChanged();

private:
    explicit PlaybackClock(QObject *parent = nullptr);
    qint64 positionLocked() const;
    void rebase(); // fold elapsed time into m_base

    mutable QMutex m_mu;
    QElapsedTimer m_timer;
    qint64 m_base = 0;      // position at the moment m_timer was (re)started
    bool m_playing = true;
    double m_speed = 1.0;
    bool m_live = true;
    std::atomic<int> m_gen{0};
    QTimer m_tick;
    QTimer m_reverseTimer;
    bool m_reverse = false;
};
