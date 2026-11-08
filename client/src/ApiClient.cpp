#include "ApiClient.h"

#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkReply>
#include <QQmlEngine>
#include <QSettings>
#include <QUrlQuery>

ApiClient *ApiClient::instance()
{
    static ApiClient *s = new ApiClient();
    return s;
}

ApiClient *ApiClient::create(QQmlEngine *, QJSEngine *)
{
    auto *s = instance();
    QJSEngine::setObjectOwnership(s, QJSEngine::CppOwnership);
    return s;
}

ApiClient::ApiClient(QObject *parent) : QObject(parent)
{
    m_poll.setInterval(2000);
    connect(&m_poll, &QTimer::timeout, this, &ApiClient::refreshCameras);
}

QString ApiClient::savedServer() const
{
    return QSettings().value("session/server", "http://localhost:7480").toString();
}

QString ApiClient::savedUser() const
{
    return QSettings().value("session/user", "admin").toString();
}

QNetworkRequest ApiClient::request(const QString &path) const
{
    QNetworkRequest req(QUrl(m_server + path));
    req.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
    if (!m_token.isEmpty())
        req.setRawHeader("Authorization", "Bearer " + m_token.toUtf8());
    req.setTransferTimeout(15000);
    return req;
}

void ApiClient::setBusy(bool b)
{
    if (m_busy != b) {
        m_busy = b;
        emit busyChanged();
    }
}

static QVariant parseBody(const QByteArray &body)
{
    if (body.isEmpty())
        return {};
    return QJsonDocument::fromJson(body).toVariant();
}

void ApiClient::handleReply(QNetworkReply *reply, const QJSValue &callback, std::function<void(const QVariant &)> onOk)
{
    connect(reply, &QNetworkReply::finished, this, [this, reply, callback, onOk]() {
        reply->deleteLater();
        const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        const QVariant data = parseBody(reply->readAll());
        QString err;
        if (reply->error() != QNetworkReply::NoError || status >= 400) {
            err = data.toMap().value("error").toString();
            if (err.isEmpty())
                err = reply->errorString();
            if (status == 401 && !m_token.isEmpty()) {
                logout();
                err = tr("Session expired, please log in again");
            }
        } else if (onOk) {
            onOk(data);
        }
        if (callback.isCallable()) {
            QJSValue cb = callback;
            QJSEngine *eng = qjsEngine(this);
            if (eng)
                cb.call({eng->toScriptValue(err.isEmpty() ? QVariant() : QVariant(err)), eng->toScriptValue(data)});
        } else if (!err.isEmpty()) {
            emit error(err);
        }
    });
}

void ApiClient::login(const QString &server, const QString &user, const QString &password, bool remember, const QJSValue &callback)
{
    QString s = server.trimmed();
    if (!s.startsWith("http://") && !s.startsWith("https://"))
        s = "http://" + s;
    QUrl u(s);
    if (u.port() == -1)
        u.setPort(7480); // default Ipvexa port when the user types just a host
    u.setPath(QString());
    s = u.toString(QUrl::StripTrailingSlash);
    m_server = s;
    m_token.clear();
    setBusy(true);
    QJsonObject body{{"username", user}, {"password", password}};
    auto *reply = m_net.post(request("/api/login"), QJsonDocument(body).toJson());
    handleReply(reply, callback, [this, remember, s, user](const QVariant &data) {
        const auto m = data.toMap();
        m_token = m.value("token").toString();
        m_user = m.value("user").toMap().value("username").toString();
        m_role = m.value("user").toMap().value("role").toString();
        QSettings st;
        st.setValue("session/server", s);
        st.setValue("session/user", user);
        st.setValue("session/token", remember ? m_token : QString());
        emit sessionChanged();
        refreshCameras();
        m_poll.start();
    });
    connect(reply, &QNetworkReply::finished, this, [this]() { setBusy(false); });
}

void ApiClient::restoreSession()
{
    QSettings st;
    const QString tok = st.value("session/token").toString();
    if (tok.isEmpty())
        return;
    m_server = st.value("session/server").toString();
    m_token = tok;
    setBusy(true);
    auto *reply = m_net.get(request("/api/me"));
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();
        setBusy(false);
        if (reply->error() != QNetworkReply::NoError) {
            m_token.clear();
            if (reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt() == 401)
                QSettings().remove("session/token");
            emit sessionChanged();
            return;
        }
        const auto m = parseBody(reply->readAll()).toMap();
        m_user = m.value("username").toString();
        m_role = m.value("role").toString();
        emit sessionChanged();
        refreshCameras();
        m_poll.start();
    });
}

void ApiClient::logout()
{
    if (!m_token.isEmpty())
        m_net.post(request("/api/logout"), QByteArray());
    m_token.clear();
    m_poll.stop();
    QSettings().remove("session/token");
    m_cameras.clear();
    emit camerasChanged();
    emit sessionChanged();
}

void ApiClient::refreshCameras()
{
    if (m_token.isEmpty())
        return;
    auto *reply = m_net.get(request("/api/cameras"));
    handleReply(reply, QJSValue(), [this](const QVariant &data) {
        const auto list = data.toList();
        if (list != m_cameras) {
            m_cameras = list;
            emit camerasChanged();
        }
    });
    if (m_pollCount++ % 15 == 0) {
        auto *sys = m_net.get(request("/api/system"));
        handleReply(sys, QJSValue(), [this](const QVariant &data) {
            m_system = data.toMap();
            emit systemChanged();
        });
    }
}

QVariantMap ApiClient::camera(int id) const
{
    for (const auto &c : m_cameras) {
        const auto m = c.toMap();
        if (m.value("id").toInt() == id)
            return m;
    }
    return {};
}

void ApiClient::fetchTimeline(int cameraId, qint64 from, qint64 to, const QJSValue &callback)
{
    auto *reply = m_net.get(request(QString("/api/cameras/%1/timeline?from=%2&to=%3").arg(cameraId).arg(from).arg(to)));
    handleReply(reply, callback);
}

void ApiClient::saveCamera(const QVariantMap &cam, const QJSValue &callback)
{
    const int id = cam.value("id").toInt();
    const QByteArray body = QJsonDocument(QJsonObject::fromVariantMap(cam)).toJson();
    QNetworkReply *reply = id > 0 ? m_net.put(request(QString("/api/cameras/%1").arg(id)), body)
                                  : m_net.post(request("/api/cameras"), body);
    handleReply(reply, callback, [this](const QVariant &) { refreshCameras(); });
}

void ApiClient::deleteCamera(int id, const QJSValue &callback)
{
    auto *reply = m_net.deleteResource(request(QString("/api/cameras/%1").arg(id)));
    handleReply(reply, callback, [this](const QVariant &) { refreshCameras(); });
}

void ApiClient::discover(const QJSValue &callback)
{
    handleReply(m_net.get(request("/api/discover")), callback);
}

void ApiClient::call(const QString &method, const QString &path, const QVariant &body, const QJSValue &callback)
{
    QNetworkRequest req = request(path);
    QByteArray data;
    if (body.isValid() && !body.isNull())
        data = QJsonDocument::fromVariant(body).toJson(QJsonDocument::Compact);
    QNetworkReply *reply = m_net.sendCustomRequest(req, method.toUtf8(), data);
    handleReply(reply, callback);
}

QString ApiClient::snapshotUrl(int cameraId) const
{
    return QString("%1/api/cameras/%2/snapshot?token=%3").arg(m_server).arg(cameraId).arg(m_token);
}

QString ApiClient::liveUrl(int cameraId, const QString &stream) const
{
    return QString("%1/api/cameras/%2/live?stream=%3&token=%4").arg(m_server).arg(cameraId).arg(stream, m_token);
}

QString ApiClient::playbackUrl(int cameraId, qint64 t, bool keyframesOnly, bool info) const
{
    QString u = QString("%1/api/cameras/%2/playback?t=%3&token=%4").arg(m_server).arg(cameraId).arg(t).arg(m_token);
    if (keyframesOnly)
        u += "&keyframes=1";
    if (info)
        u += "&info=1";
    return u;
}
