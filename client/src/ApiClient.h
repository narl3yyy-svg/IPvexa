#pragma once

#include <QObject>
#include <QJSValue>
#include <QNetworkAccessManager>
#include <QTimer>
#include <QVariant>
#include <QtQml/qqmlregistration.h>

class QQmlEngine;
class QJSEngine;

// Talks to ipvexa-server's REST API. Exposed to QML as the `Api` singleton.
class ApiClient : public QObject
{
    Q_OBJECT
    QML_NAMED_ELEMENT(Api)
    QML_SINGLETON

    Q_PROPERTY(QString serverUrl READ serverUrl NOTIFY sessionChanged)
    Q_PROPERTY(QString username READ username NOTIFY sessionChanged)
    Q_PROPERTY(QString role READ role NOTIFY sessionChanged)
    Q_PROPERTY(QString fullName READ fullName NOTIFY sessionChanged)
    Q_PROPERTY(QVariantMap permissions READ permissions NOTIFY sessionChanged)
    Q_PROPERTY(bool isAdmin READ isAdmin NOTIFY sessionChanged)
    Q_PROPERTY(bool canPlayback READ canPlayback NOTIFY sessionChanged)
    Q_PROPERTY(bool canPtz READ canPtz NOTIFY sessionChanged)
    Q_PROPERTY(bool canExport READ canExport NOTIFY sessionChanged)
    Q_PROPERTY(bool loggedIn READ loggedIn NOTIFY sessionChanged)
    Q_PROPERTY(bool busy READ busy NOTIFY busyChanged)
    Q_PROPERTY(QVariantList cameras READ cameras NOTIFY camerasChanged)
    Q_PROPERTY(QVariantMap system READ system NOTIFY systemChanged)
    Q_PROPERTY(QString savedServer READ savedServer CONSTANT)
    Q_PROPERTY(QString savedUser READ savedUser CONSTANT)

public:
    static ApiClient *instance();
    static ApiClient *create(QQmlEngine *, QJSEngine *);

    QString serverUrl() const { return m_server; }
    QString token() const { return m_token; }
    QString username() const { return m_user; }
    QString role() const { return m_role; }
    QString fullName() const { return m_me.value("full_name").toString(); }
    QVariantMap permissions() const { return m_me.value("permissions").toMap(); }
    bool isAdmin() const { return m_role == "admin"; }
    bool canPlayback() const { return isAdmin() || permissions().value("playback").toBool(); }
    bool canPtz() const { return isAdmin() || permissions().value("ptz").toBool(); }
    bool canExport() const { return isAdmin() || (canPlayback() && permissions().value("export").toBool()); }
    bool loggedIn() const { return !m_token.isEmpty(); }
    bool busy() const { return m_busy; }
    QVariantList cameras() const { return m_cameras; }
    QVariantMap system() const { return m_system; }
    QString savedServer() const;
    QString savedUser() const;

    Q_INVOKABLE void login(const QString &server, const QString &user, const QString &password, bool remember, const QJSValue &callback = {});
    Q_INVOKABLE void restoreSession();
    Q_INVOKABLE void refreshMe();
    Q_INVOKABLE void logout();
    Q_INVOKABLE void refreshCameras();
    Q_INVOKABLE QVariantMap camera(int id) const;

    Q_INVOKABLE void fetchTimeline(int cameraId, qint64 from, qint64 to, const QJSValue &callback);
    Q_INVOKABLE void saveCamera(const QVariantMap &cam, const QJSValue &callback);
    Q_INVOKABLE void deleteCamera(int id, const QJSValue &callback);
    Q_INVOKABLE void discover(const QJSValue &callback);
    Q_INVOKABLE QString snapshotUrl(int cameraId) const;
    // Generic JSON request: method "GET"/"POST"/"PUT"/"DELETE", path like "/api/cameras/3/ptz/move".
    Q_INVOKABLE void call(const QString &method, const QString &path, const QVariant &body = {}, const QJSValue &callback = {});
    // Download a server path to a local file. progress(received, total) fires on the
    // downloadProgress signal; callback(error, filePath) when done.
    Q_INVOKABLE void download(const QString &path, const QString &filePath, const QJSValue &callback = {});
    Q_INVOKABLE void cancelDownload();
    Q_INVOKABLE QString videosDir() const;
    Q_INVOKABLE QString frameUrl(int cameraId, qint64 t) const;
    Q_INVOKABLE QString eventThumbUrl(qint64 eventId) const;

    QString liveUrl(int cameraId, const QString &stream) const;
    QString playbackUrl(int cameraId, qint64 t, bool keyframesOnly, bool info) const;

signals:
    void sessionChanged();
    void busyChanged();
    void camerasChanged();
    void systemChanged();
    void error(const QString &message);
    void downloadProgress(qint64 received, qint64 total);

private:
    explicit ApiClient(QObject *parent = nullptr);
    QNetworkRequest request(const QString &path) const;
    void handleReply(class QNetworkReply *reply, const QJSValue &callback, std::function<void(const QVariant &)> onOk = {});
    void setBusy(bool b);

    QNetworkAccessManager m_net;
    QTimer m_poll;
    QString m_server, m_token, m_user, m_role;
    QVariantList m_cameras;
    QVariantMap m_system;
    QVariantMap m_me;
    class QNetworkReply *m_download = nullptr;
    void setMe(const QVariantMap &me);
    bool m_busy = false;
    int m_pollCount = 0;
};
