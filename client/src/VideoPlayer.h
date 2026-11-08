#pragma once

#include <QObject>
#include <QPointer>
#include <QMutex>
#include <QVideoFrame>
#include <QVideoSink>
#include <QtQml/qqmlregistration.h>
#include <atomic>
#include <thread>

// Plays one camera into a QVideoSink (from a QML VideoOutput).
// Live mode pulls the server's live stream; playback mode follows the shared Clock.
class VideoPlayer : public QObject
{
    Q_OBJECT
    QML_ELEMENT

    Q_PROPERTY(QVideoSink *videoSink READ videoSink WRITE setVideoSink NOTIFY videoSinkChanged)
    Q_PROPERTY(int cameraId READ cameraId WRITE setCameraId NOTIFY cameraIdChanged)
    Q_PROPERTY(QString stream READ stream WRITE setStream NOTIFY streamChanged)
    Q_PROPERTY(bool live READ live WRITE setLive NOTIFY liveChanged)
    Q_PROPERTY(bool active READ active WRITE setActive NOTIFY activeChanged)
    Q_PROPERTY(QString state READ state NOTIFY stateChanged)
    Q_PROPERTY(QString info READ info NOTIFY infoChanged)
    Q_PROPERTY(qint64 frameTime READ frameTime NOTIFY frameTimeChanged)

public:
    explicit VideoPlayer(QObject *parent = nullptr);
    ~VideoPlayer() override;

    QVideoSink *videoSink() const { return m_sink; }
    void setVideoSink(QVideoSink *s);
    int cameraId() const { return m_cameraId; }
    void setCameraId(int id);
    QString stream() const { return m_stream; }
    void setStream(const QString &s);
    bool live() const { return m_live; }
    void setLive(bool l);
    bool active() const { return m_active; }
    void setActive(bool a);
    QString state() const { return m_state; }
    QString info() const { return m_info; }
    qint64 frameTime() const { return m_frameTime; }

    // Called from the decoder thread.
    struct Session;
    void postState(const QString &state);
    void postInfo(const QString &info);
    void postFrame(const QVideoFrame &f, qint64 wallMs);
    bool shouldStop(int myGen) const { return m_stop.load() || m_gen.load() != myGen; }

signals:
    void videoSinkChanged();
    void cameraIdChanged();
    void streamChanged();
    void liveChanged();
    void activeChanged();
    void stateChanged();
    void infoChanged();
    void frameTimeChanged();

private:
    void restart();
    void stopThread();
    void clearPicture();
    void deliverFrame();

    QPointer<QVideoSink> m_sink;
    int m_cameraId = 0;
    QString m_stream = "sub";
    bool m_live = true;
    bool m_active = true;
    QString m_state = "idle";
    QString m_info;
    qint64 m_frameTime = 0;

    std::thread m_thread;
    std::atomic<bool> m_stop{false};
    std::atomic<int> m_gen{0};
    int m_clockGen = -1;

    QMutex m_frameMu;
    QVideoFrame m_pending;
    qint64 m_pendingTime = 0;
    std::atomic<bool> m_deliveryQueued{false};
};
