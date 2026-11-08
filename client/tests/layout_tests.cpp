// Runs tests/layout_engine.test.js against qml/LayoutEngine.js in a plain QJSEngine.
#include <QCoreApplication>
#include <QFile>
#include <QJSEngine>
#include <QTextStream>

static QString readFile(const QString &path)
{
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly))
        qFatal("cannot open %s", qPrintable(path));
    return QString::fromUtf8(f.readAll());
}

int main(int argc, char **argv)
{
    QCoreApplication app(argc, argv);
    QJSEngine engine;
    engine.installExtensions(QJSEngine::ConsoleExtension);
    engine.globalObject().setProperty("print", engine.evaluate("(function(m){ console.log(m) })"));

    QString lib = readFile(QStringLiteral(IPVEXA_SOURCE_DIR "/qml/LayoutEngine.js"));
    lib.replace(".pragma library", "");
    QJSValue r = engine.evaluate(lib, "LayoutEngine.js");
    if (r.isError())
        qFatal("LayoutEngine.js: %s", qPrintable(r.toString()));

    r = engine.evaluate(readFile(QStringLiteral(IPVEXA_SOURCE_DIR "/tests/layout_engine.test.js")), "layout_engine.test.js");
    if (r.isError()) {
        QTextStream(stderr) << "test error: " << r.toString() << " line " << r.property("lineNumber").toInt() << "\n";
        return 2;
    }
    return r.toInt() == 0 ? 0 : 1;
}
