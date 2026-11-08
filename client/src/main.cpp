#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQuickStyle>
#include <QPalette>
#include <QIcon>
#include <QTimer>

#include "PlaybackClock.h"

extern "C" {
#include <libavutil/log.h>
}

int main(int argc, char *argv[])
{
    QGuiApplication app(argc, argv);
    // These names locate the saved settings (~/.config/Ipvexa); the visible name is
    // the display name below.
    app.setApplicationName("Ipvexa");
    app.setOrganizationName("Ipvexa");
    app.setApplicationDisplayName("IPvexa");
    app.setApplicationVersion("0.3.0");
    app.setDesktopFileName("ipvexa");

    // FFmpeg's own messages (e.g. a camera's damaged first frames) are only useful when
    // debugging; set IPVEXA_DEBUG=1 to see them.
    av_log_set_level(qEnvironmentVariableIsEmpty("IPVEXA_DEBUG") ? AV_LOG_FATAL : AV_LOG_WARNING);

    // Fusion + a dark palette gives native-feeling, consistently dark controls on KDE and elsewhere.
    QQuickStyle::setStyle("Fusion");
    QPalette p;
    p.setColor(QPalette::Window, QColor("#14171c"));
    p.setColor(QPalette::WindowText, QColor("#e6e8ec"));
    p.setColor(QPalette::Base, QColor("#0f1115"));
    p.setColor(QPalette::AlternateBase, QColor("#1a1e25"));
    p.setColor(QPalette::Text, QColor("#e6e8ec"));
    p.setColor(QPalette::Button, QColor("#1f242c"));
    p.setColor(QPalette::ButtonText, QColor("#e6e8ec"));
    p.setColor(QPalette::Highlight, QColor("#2f8cff"));
    p.setColor(QPalette::HighlightedText, QColor("#ffffff"));
    p.setColor(QPalette::ToolTipBase, QColor("#1f242c"));
    p.setColor(QPalette::ToolTipText, QColor("#e6e8ec"));
    p.setColor(QPalette::PlaceholderText, QColor("#6b7380"));
    p.setColor(QPalette::Mid, QColor("#2a303a"));
    p.setColor(QPalette::Dark, QColor("#0b0d10"));
    p.setColor(QPalette::Light, QColor("#323946"));
    p.setColor(QPalette::Disabled, QPalette::Text, QColor("#5a616d"));
    p.setColor(QPalette::Disabled, QPalette::ButtonText, QColor("#5a616d"));
    QGuiApplication::setPalette(p);

    QQmlApplicationEngine engine;
    QObject::connect(&engine, &QQmlApplicationEngine::objectCreationFailed, &app,
                     []() { QCoreApplication::exit(1); }, Qt::QueuedConnection);
    engine.loadFromModule("Ipvexa", "Main");

    // --seek <minutes>: start in playback N minutes ago (handy for testing and support).
    const QStringList args = app.arguments();
    const int seekIdx = args.indexOf("--seek");
    if (seekIdx >= 0 && seekIdx + 1 < args.size()) {
        const double minutes = args.at(seekIdx + 1).toDouble();
        QTimer::singleShot(1500, [minutes]() {
            auto *clock = PlaybackClock::instance();
            clock->seek(clock->now() - qint64(minutes * 60000));
        });
    }
    return app.exec();
}
