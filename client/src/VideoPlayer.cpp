#include "VideoPlayer.h"
#include "ApiClient.h"
#include "PlaybackClock.h"
#include "LivePacer.h"

#include <QJsonDocument>
#include <QJsonObject>
#include <QElapsedTimer>
#include <QLibrary>
#include <QAbstractVideoBuffer>
#include <QVideoFrameFormat>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <deque>
#include <mutex>
#include <cmath>
#include <cstring>
#include <memory>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/hwcontext.h>
#include <libavutil/imgutils.h>
#include <libavutil/pixdesc.h>
#include <libswscale/swscale.h>
}

using namespace std::chrono_literals;

namespace {

struct Config {
    int cameraId = 0;
    QString stream;
    bool live = true;
    QString server, token;
};

// Everything the interrupt callback needs to abort blocking network calls.
struct Interrupt {
    VideoPlayer *player;
    int gen;
    int clockGen; // -1 = don't watch the clock (live mode)
    std::atomic<bool> abort{false}; // end the current session (stops the live reader)
};

int interruptCb(void *opaque)
{
    auto *i = static_cast<Interrupt *>(opaque);
    if (i->abort.load(std::memory_order_relaxed) || i->player->shouldStop(i->gen))
        return 1;
    if (i->clockGen >= 0 && PlaybackClock::instance()->generation() != i->clockGen)
        return 1;
    return 0;
}

// Hardware decoders to try, best first: NVIDIA (CUDA/NVDEC), then Intel/AMD (VAAPI).
const AVHWDeviceType kHwTypes[] = {AV_HWDEVICE_TYPE_CUDA, AV_HWDEVICE_TYPE_VAAPI};

// Only try CUDA when the NVIDIA driver is installed; otherwise FFmpeg prints
// "Cannot load libcuda.so.1" errors for every stream on Intel/AMD machines.
bool hwTypeAvailable(AVHWDeviceType type)
{
    if (type != AV_HWDEVICE_TYPE_CUDA)
        return true;
    static const bool hasCuda = QLibrary("cuda", 1).load();
    return hasCuda;
}

struct HwCtx {
    AVPixelFormat pixFmt = AV_PIX_FMT_NONE;
};

AVPixelFormat pickFormat(AVCodecContext *ctx, const AVPixelFormat *fmts)
{
    auto *hw = static_cast<HwCtx *>(ctx->opaque);
    for (const AVPixelFormat *p = fmts; *p != AV_PIX_FMT_NONE; ++p)
        if (hw && *p == hw->pixFmt)
            return *p;
    // Hardware path unavailable for this stream: fall back to software.
    for (const AVPixelFormat *p = fmts; *p != AV_PIX_FMT_NONE; ++p) {
        const AVPixFmtDescriptor *d = av_pix_fmt_desc_get(*p);
        if (d && !(d->flags & AV_PIX_FMT_FLAG_HWACCEL))
            return *p;
    }
    return fmts[0];
}

bool sleepInterruptible(VideoPlayer *p, int gen, int clockGen, int ms)
{
    for (int waited = 0; waited < ms; waited += 20) {
        if (p->shouldStop(gen) || (clockGen >= 0 && PlaybackClock::instance()->generation() != clockGen))
            return false;
        std::this_thread::sleep_for(20ms);
    }
    return true;
}

// Hands a decoded frame's own memory to Qt instead of copying it: Qt uploads it
// to the GPU straight from FFmpeg's buffer (a 4K frame is 12 MB, so this saves a
// full copy per frame). The buffer holds a reference, so the decoder can't reuse
// the memory until Qt is done with the frame.
class AvFrameBuffer : public QAbstractVideoBuffer
{
public:
    AvFrameBuffer(AVFrame *f, const QVideoFrameFormat &fmt, int planes) : m_frame(f), m_fmt(fmt), m_planes(planes) {}
    ~AvFrameBuffer() override { av_frame_free(&m_frame); }
    MapData map(QVideoFrame::MapMode) override
    {
        MapData d;
        d.planeCount = m_planes;
        for (int i = 0; i < m_planes; ++i) {
            const int h = i == 0 ? m_frame->height : (m_frame->height + 1) / 2;
            d.bytesPerLine[i] = m_frame->linesize[i];
            d.data[i] = m_frame->data[i];
            d.dataSize[i] = m_frame->linesize[i] * h;
        }
        return d;
    }
    QVideoFrameFormat format() const override { return m_fmt; }

private:
    AVFrame *m_frame;
    QVideoFrameFormat m_fmt;
    int m_planes;
};

// Convert a decoded (software) frame to a QVideoFrame without changing pixel layout when possible.
class FrameConverter
{
public:
    ~FrameConverter() { sws_freeContext(m_sws); }

    QVideoFrame convert(const AVFrame *f)
    {
        QVideoFrameFormat::PixelFormat qfmt;
        const AVFrame *src = f;
        switch (f->format) {
        case AV_PIX_FMT_NV12: qfmt = QVideoFrameFormat::Format_NV12; break;
        case AV_PIX_FMT_P010LE: qfmt = QVideoFrameFormat::Format_P010; break;
        case AV_PIX_FMT_YUV420P:
        case AV_PIX_FMT_YUVJ420P: qfmt = QVideoFrameFormat::Format_YUV420P; break;
        default:
            src = toYuv420(f);
            if (!src)
                return {};
            qfmt = QVideoFrameFormat::Format_YUV420P;
        }
        QVideoFrameFormat fmt(QSize(f->width, f->height), qfmt);
        const bool full = f->color_range == AVCOL_RANGE_JPEG || f->format == AV_PIX_FMT_YUVJ420P;
        fmt.setColorRange(full ? QVideoFrameFormat::ColorRange_Full : QVideoFrameFormat::ColorRange_Video);
        fmt.setColorSpace(f->height >= 720 ? QVideoFrameFormat::ColorSpace_BT709 : QVideoFrameFormat::ColorSpace_BT601);
        const int nplanes = qfmt == QVideoFrameFormat::Format_YUV420P ? 3 : 2;
        if (src == f && f->buf[0] && f->linesize[0] > 0 && f->linesize[1] > 0 && (nplanes == 2 || f->linesize[2] > 0)) {
            AVFrame *ref = av_frame_clone(f); // shares the data, no copy
            if (ref)
                return QVideoFrame(std::make_unique<AvFrameBuffer>(ref, fmt, nplanes));
        }
        QVideoFrame vf(fmt);
        if (!vf.map(QVideoFrame::WriteOnly))
            return {};
        const int planes = vf.planeCount();
        for (int i = 0; i < planes; ++i) {
            const int h = (i == 0) ? f->height : (f->height + 1) / 2;
            const int dstStride = vf.bytesPerLine(i);
            const int srcStride = src->linesize[i];
            const int rowBytes = std::min(dstStride, std::abs(srcStride));
            uchar *dst = vf.bits(i);
            const uint8_t *s = src->data[i];
            for (int y = 0; y < h; ++y)
                std::memcpy(dst + y * dstStride, s + y * srcStride, rowBytes);
        }
        vf.unmap();
        return vf;
    }

private:
    const AVFrame *toYuv420(const AVFrame *f)
    {
        m_sws = sws_getCachedContext(m_sws, f->width, f->height, AVPixelFormat(f->format),
                                     f->width, f->height, AV_PIX_FMT_YUV420P, SWS_BILINEAR, nullptr, nullptr, nullptr);
        if (!m_sws)
            return nullptr;
        if (!m_tmp || m_tmp->width != f->width || m_tmp->height != f->height) {
            av_frame_free(&m_tmp);
            m_tmp = av_frame_alloc();
            m_tmp->format = AV_PIX_FMT_YUV420P;
            m_tmp->width = f->width;
            m_tmp->height = f->height;
            if (av_frame_get_buffer(m_tmp, 32) < 0)
                return nullptr;
        }
        sws_scale(m_sws, f->data, f->linesize, 0, f->height, m_tmp->data, m_tmp->linesize);
        m_tmp->color_range = f->color_range;
        return m_tmp;
    }
    SwsContext *m_sws = nullptr;
    AVFrame *m_tmp = nullptr;
};

struct PlayInfo {
    qint64 start = 0, runEnd = 0;
    bool open = false;
    double tsOffset = 0;
    int httpStatus = 0;
};

// Fetch ?info=1 for a playback request, using libavformat's HTTP client.
bool fetchPlayInfo(const QString &url, Interrupt *intr, PlayInfo *out)
{
    AVIOContext *io = nullptr;
    AVIOInterruptCB cb{interruptCb, intr};
    AVDictionary *opts = nullptr;
    av_dict_set(&opts, "rw_timeout", "8000000", 0);
    int r = avio_open2(&io, url.toUtf8().constData(), AVIO_FLAG_READ, &cb, &opts);
    av_dict_free(&opts);
    if (r < 0)
        return false; // includes 404 = no recording at/after this time
    QByteArray body;
    char buf[4096];
    int n;
    while ((n = avio_read(io, reinterpret_cast<unsigned char *>(buf), sizeof buf)) > 0)
        body.append(buf, n);
    avio_closep(&io);
    const auto o = QJsonDocument::fromJson(body).object();
    if (!o.contains("start"))
        return false;
    out->start = o.value("start").toInteger();
    out->runEnd = o.value("run_end").toInteger();
    out->open = o.value("open").toBool();
    out->tsOffset = o.value("ts_offset").toDouble();
    return true;
}

// Sleep up to ms in small steps, returning false if the player is stopping.
bool sleepFine(VideoPlayer *p, int gen, qint64 ms)
{
    while (ms > 0) {
        if (p->shouldStop(gen))
            return false;
        const qint64 step = std::min<qint64>(ms, 5);
        std::this_thread::sleep_for(std::chrono::milliseconds(step));
        ms -= step;
    }
    return true;
}

struct SessionResult {
    bool opened = false;
    qint64 lastWall = 0; // wall time of the last frame shown (playback)
    bool hwFailed = false;
};

// Open a stream and decode until EOF, error, or interruption.
// In playback mode frames are paced against the shared Clock using `info` to map timestamps.
SessionResult runSession(VideoPlayer *p, Interrupt *intr, const QString &url, bool live,
                         const PlayInfo *info, bool allowHw)
{
    SessionResult res;
    intr->abort = false;
    AVFormatContext *fmt = avformat_alloc_context();
    fmt->interrupt_callback = {interruptCb, intr};
    AVDictionary *opts = nullptr;
    av_dict_set(&opts, "rw_timeout", "8000000", 0);
    if (live) {
        // No "fflags nobuffer" here: during stream probing it would throw away the
        // packets read so far, including the keyframe the server sends first. Streams
        // with long keyframe intervals (e.g. Dahua HEVC) then stay black. The flag is
        // set after probing instead.
        av_dict_set(&opts, "max_delay", "0", 0);
        av_dict_set(&opts, "probesize", "1000000", 0);
        av_dict_set(&opts, "analyzeduration", "1000000", 0);
    } else {
        av_dict_set(&opts, "probesize", "2000000", 0);
    }
    if (avformat_open_input(&fmt, url.toUtf8().constData(), nullptr, &opts) < 0) {
        av_dict_free(&opts);
        return res;
    }
    av_dict_free(&opts);

    AVCodecContext *dec = nullptr;
    AVBufferRef *hwDev = nullptr;
    HwCtx hw;
    AVPacket *pkt = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    AVFrame *swFrame = av_frame_alloc();
    FrameConverter conv;
    int vs = -1;
    const AVCodec *codec = nullptr;
    QString hwName = "CPU";

    auto cleanup = [&]() {
        av_frame_free(&swFrame);
        av_frame_free(&frame);
        av_packet_free(&pkt);
        avcodec_free_context(&dec);
        av_buffer_unref(&hwDev);
        avformat_close_input(&fmt);
    };

    if (avformat_find_stream_info(fmt, nullptr) < 0 ||
        (vs = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, &codec, 0)) < 0 || !codec) {
        cleanup();
        return res;
    }
    if (live)
        fmt->flags |= AVFMT_FLAG_NOBUFFER; // probed packets stay queued; new ones aren't buffered
    AVStream *st = fmt->streams[vs];
    dec = avcodec_alloc_context3(codec);
    avcodec_parameters_to_context(dec, st->codecpar);
    dec->pkt_timebase = st->time_base;

    if (allowHw) {
        for (AVHWDeviceType type : kHwTypes) {
            if (!hwTypeAvailable(type))
                continue;
            for (int i = 0;; ++i) {
                const AVCodecHWConfig *cfg = avcodec_get_hw_config(codec, i);
                if (!cfg)
                    break;
                if ((cfg->methods & AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX) && cfg->device_type == type) {
                    if (av_hwdevice_ctx_create(&hwDev, type, nullptr, nullptr, 0) == 0) {
                        hw.pixFmt = cfg->pix_fmt;
                        hwName = type == AV_HWDEVICE_TYPE_CUDA ? "NVDEC" : "VAAPI";
                    }
                    break;
                }
            }
            if (hwDev)
                break;
        }
    }
    if (hwDev) {
        dec->hw_device_ctx = av_buffer_ref(hwDev);
        dec->opaque = &hw;
        dec->get_format = pickFormat;
    } else {
        dec->thread_count = 0; // auto
    }
    if (live) {
        dec->flags |= AV_CODEC_FLAG_LOW_DELAY;
        dec->flags |= AV_CODEC_FLAG_COPY_OPAQUE; // frames carry their packet's arrival time
        if (!hwDev)
            dec->thread_type = FF_THREAD_SLICE; // frame threading would add latency
    }
    if (avcodec_open2(dec, codec, nullptr) < 0) {
        cleanup();
        return res;
    }
    res.opened = true;
    p->postState("playing");

    const double tb = av_q2d(st->time_base);
    QElapsedTimer fpsTimer;
    fpsTimer.start();
    int frames = 0, decodeErrors = 0;
    auto *clock = PlaybackClock::instance();
    LivePacer pacer;
    QElapsedTimer steady;
    steady.start();
    qint64 lastShown = -1, maxGap = 0; // frame timing, logged with IPVEXA_DEBUG=1
    static const bool debugTiming = !qEnvironmentVariableIsEmpty("IPVEXA_DEBUG");

    auto handleFrame = [&](AVFrame *f) -> bool {
        AVFrame *out = f;
        if (hwDev && f->format == hw.pixFmt) {
            av_frame_unref(swFrame);
            if (av_hwframe_transfer_data(swFrame, f, 0) < 0)
                return true;
            av_frame_copy_props(swFrame, f);
            out = swFrame;
        }
        if (live && f->best_effort_timestamp != AV_NOPTS_VALUE) {
            const double ptsMs = double(f->best_effort_timestamp) * tb * 1000.0;
            const qint64 now = steady.elapsed();
            const qint64 arrived = f->opaque ? qint64(reinterpret_cast<intptr_t>(f->opaque)) : now;
            const qint64 waitMs = pacer.wait(ptsMs, arrived, now, p->liveBufferMs());
            if (waitMs > 0 && !sleepFine(p, intr->gen, waitMs))
                return false;
        }
        qint64 wall = clock->now();
        if (!live && info) {
            const int64_t ts = f->best_effort_timestamp;
            if (ts == AV_NOPTS_VALUE)
                return true;
            wall = info->start + qint64((double(ts) * tb - info->tsOffset) * 1000.0);
            if (wall < info->start - 5)
                return true; // decoded only to reach the seek point
            // Pace against the shared clock.
            for (;;) {
                if (p->shouldStop(intr->gen) || clock->generation() != intr->clockGen)
                    return false;
                const qint64 pos = clock->position();
                if (wall <= pos + 15)
                    break;
                std::this_thread::sleep_for(std::chrono::milliseconds(std::clamp<qint64>((wall - pos) / 2, 2, 20)));
            }
            if (wall < clock->position() - 400 && !clock->fastForward())
                return true; // running behind: drop rather than lag
            res.lastWall = wall;
        }
        QVideoFrame vf = conv.convert(out);
        if (vf.isValid())
            p->postFrame(vf, wall);
        ++frames;
        const qint64 shownAt = steady.elapsed();
        if (lastShown >= 0)
            maxGap = std::max(maxGap, shownAt - lastShown);
        lastShown = shownAt;
        if (fpsTimer.elapsed() >= 1000) {
            const double fps = frames * 1000.0 / fpsTimer.restart();
            if (debugTiming && live)
                qInfo("camera %d: %.1f fps shown, longest pause %lld ms", p->cameraId(), fps, (long long)maxGap);
            maxGap = 0;
            frames = 0;
            p->postInfo(QString("%1 %2×%3 · %4 fps · %5")
                            .arg(QString(codec->name).toUpper())
                            .arg(f->width).arg(f->height)
                            .arg(fps, 0, 'f', fps < 10 ? 1 : 0)
                            .arg(hwName), fps);
        }
        return true;
    };

    // Live: a reader thread takes packets off the network the moment they arrive and
    // notes when, so the pacer knows real arrival times even while frames wait to be
    // shown, and the server never sees a slow viewer.
    struct {
        std::mutex m;
        std::condition_variable cv;
        std::deque<AVPacket *> q;
        bool done = false;
    } lq;
    std::thread reader;
    if (live) {
        reader = std::thread([&] {
            for (;;) {
                AVPacket *pk = av_packet_alloc();
                if (!pk || av_read_frame(fmt, pk) < 0) {
                    av_packet_free(&pk);
                    break;
                }
                if (pk->stream_index != vs) {
                    av_packet_free(&pk);
                    continue;
                }
                pk->opaque = reinterpret_cast<void *>(intptr_t(steady.elapsed()));
                std::lock_guard<std::mutex> l(lq.m);
                lq.q.push_back(pk);
                lq.cv.notify_one();
            }
            std::lock_guard<std::mutex> l(lq.m);
            lq.done = true;
            lq.cv.notify_one();
        });
    }
    auto nextPacket = [&]() -> bool {
        if (!live)
            return av_read_frame(fmt, pkt) >= 0;
        std::unique_lock<std::mutex> l(lq.m);
        lq.cv.wait(l, [&] { return !lq.q.empty() || lq.done; });
        if (lq.q.empty())
            return false;
        AVPacket *pk = lq.q.front();
        lq.q.pop_front();
        l.unlock();
        // Decoding can't keep up at all (20 s behind): reconnect at real time instead.
        if (steady.elapsed() - qint64(reinterpret_cast<intptr_t>(pk->opaque)) > 20000) {
            av_packet_free(&pk);
            return false;
        }
        av_packet_move_ref(pkt, pk);
        av_packet_free(&pk);
        return true;
    };

    bool running = true;
    while (running && nextPacket()) {
        if (pkt->stream_index == vs) {
            if (avcodec_send_packet(dec, pkt) < 0) {
                if (++decodeErrors > 50 && hwDev) {
                    res.hwFailed = true;
                    running = false;
                }
            }
            while (running) {
                int r = avcodec_receive_frame(dec, frame);
                if (r == AVERROR(EAGAIN) || r == AVERROR_EOF)
                    break;
                if (r < 0) {
                    if (++decodeErrors > 50 && hwDev) {
                        res.hwFailed = true;
                        running = false;
                    }
                    break;
                }
                decodeErrors = 0;
                running = handleFrame(frame);
                av_frame_unref(frame);
            }
        }
        av_packet_unref(pkt);
    }
    if (reader.joinable()) {
        intr->abort = true; // ends the reader's blocking read
        reader.join();
        for (AVPacket *pk : lq.q)
            av_packet_free(&pk);
    }
    cleanup();
    return res;
}

void decoderMain(VideoPlayer *p, Config cfg, int gen)
{
    auto *clock = PlaybackClock::instance();
    bool allowHw = qEnvironmentVariableIsEmpty("IPVEXA_NO_HWDEC");
    int failures = 0;

    while (!p->shouldStop(gen)) {
        if (cfg.live) {
            Interrupt intr{p, gen, -1};
            p->postState(failures == 0 ? "connecting" : "reconnecting");
            const QString url = QString("%1/api/cameras/%2/live?stream=%3&token=%4")
                                    .arg(cfg.server).arg(cfg.cameraId).arg(cfg.stream, cfg.token);
            SessionResult r = runSession(p, &intr, url, true, nullptr, allowHw);
            if (r.hwFailed)
                allowHw = false;
            if (p->shouldStop(gen))
                break;
            failures = r.opened ? 1 : failures + 1;
            p->postState("offline");
            sleepInterruptible(p, gen, -1, std::min(failures, 5) * 1000);
            continue;
        }

        // Playback: find the recording run at the clock's position and play it.
        // Small tiles ask for the recorded low-quality stream (much lighter to decode,
        // so several tiles play back smoothly) and fall back to the main recording
        // when there is none at this time.
        const int cgen = clock->generation();
        Interrupt intr{p, gen, cgen};
        qint64 target = clock->position();
        p->postState("loading");
        auto infoUrl = [&](const QString &stream) {
            return QString("%1/api/cameras/%2/playback?t=%3&info=1&stream=%4&token=%5")
                .arg(cfg.server).arg(cfg.cameraId).arg(target).arg(stream, cfg.token);
        };
        PlayInfo info;
        QString recStream = "main";
        bool found = false;
        if (cfg.stream == "sub" && fetchPlayInfo(infoUrl("sub"), &intr, &info)) {
            found = true;
            recStream = "sub";
        }
        if (!found || info.start > target + 3000) {
            PlayInfo mainInfo;
            if (fetchPlayInfo(infoUrl("main"), &intr, &mainInfo) && (!found || mainInfo.start < info.start)) {
                info = mainInfo;
                recStream = "main";
                found = true;
            }
        }
        if (!found) {
            if (p->shouldStop(gen))
                break;
            if (clock->generation() == cgen)
                p->postState("nodata");
            sleepInterruptible(p, gen, cgen, 1500);
            continue;
        }
        // Gap in the recording: wait (showing "no data") until the clock reaches the next footage.
        while (clock->generation() == cgen && !p->shouldStop(gen) && clock->position() < info.start - 250) {
            p->postState("nodata");
            if (!clock->playing()) {
                sleepInterruptible(p, gen, cgen, 200);
                continue;
            }
            sleepInterruptible(p, gen, cgen, 100);
        }
        if (clock->generation() != cgen || p->shouldStop(gen))
            continue;
        target = std::max(info.start, std::min(clock->position(), info.runEnd));
        const QString url = QString("%1/api/cameras/%2/playback?t=%3&stream=%4&token=%5%6")
                                .arg(cfg.server).arg(cfg.cameraId).arg(target).arg(recStream, cfg.token)
                                .arg(clock->fastForward() ? "&keyframes=1" : "");
        info.start = target; // the server starts the stream exactly at the time we asked for
        SessionResult r = runSession(p, &intr, url, false, &info, allowHw);
        if (r.hwFailed)
            allowHw = false;
        if (!r.opened)
            sleepInterruptible(p, gen, cgen, 1000);
        else if (clock->generation() == cgen && r.lastWall > 0 && r.lastWall < info.runEnd - 2000 && !info.open)
            sleepInterruptible(p, gen, cgen, 200); // stream ended early; loop picks up from the clock
        // Otherwise loop: the next request picks up the next run (or the live edge).
    }
}

} // namespace

VideoPlayer::VideoPlayer(QObject *parent) : QObject(parent) {}

VideoPlayer::~VideoPlayer()
{
    stopThread();
}

void VideoPlayer::setVideoSink(QVideoSink *s)
{
    if (m_sink == s)
        return;
    m_sink = s;
    emit videoSinkChanged();
}

void VideoPlayer::setCameraId(int id)
{
    if (m_cameraId == id)
        return;
    m_cameraId = id;
    emit cameraIdChanged();
    stopThread();
    clearPicture(); // don't show the previous camera's picture
    restart();
}

void VideoPlayer::setStream(const QString &s)
{
    if (m_stream == s)
        return;
    m_stream = s;
    emit streamChanged();
    restart(); // playback also switches between the recorded main and low-quality streams
}

void VideoPlayer::setLive(bool l)
{
    if (m_live == l)
        return;
    m_live = l;
    emit liveChanged();
    restart();
}

void VideoPlayer::setLiveBufferMs(int ms)
{
    ms = qBound(0, ms, 5000);
    if (m_liveBufferMs.exchange(ms) != ms)
        emit liveBufferMsChanged(); // applies from the next frame; no reconnect needed
}

void VideoPlayer::setActive(bool a)
{
    if (m_active == a)
        return;
    m_active = a;
    emit activeChanged();
    restart();
}

void VideoPlayer::stopThread()
{
    m_stop = true;
    m_gen++;
    if (m_thread.joinable())
        m_thread.join();
    m_stop = false;
    // Drop any frame the old thread queued before it stopped, so it can't repaint later.
    QMutexLocker l(&m_frameMu);
    m_pending = QVideoFrame();
}

void VideoPlayer::clearPicture()
{
    if (m_sink)
        m_sink->setVideoFrame(QVideoFrame());
}

void VideoPlayer::restart()
{
    stopThread();
    auto *api = ApiClient::instance();
    if (m_cameraId <= 0 || !m_active || !api->loggedIn()) {
        clearPicture();
        postState("idle");
        return;
    }
    Config cfg{m_cameraId, m_stream, m_live, api->serverUrl(), api->token()};
    const int gen = m_gen.load();
    m_thread = std::thread(decoderMain, this, cfg, gen);
}

void VideoPlayer::postState(const QString &state)
{
    QMetaObject::invokeMethod(this, [this, state]() {
        if (m_state != state) {
            m_state = state;
            emit stateChanged();
        }
    }, Qt::QueuedConnection);
}

void VideoPlayer::postInfo(const QString &info, double fps)
{
    QMetaObject::invokeMethod(this, [this, info, fps]() {
        if (m_info != info) {
            m_info = info;
            if (fps >= 3) // ignore rates measured while paused or stalled
                m_fps = fps;
            emit infoChanged();
        }
    }, Qt::QueuedConnection);
}

// Keep only the newest frame; if the UI is busy, older frames are skipped instead of queueing up.
void VideoPlayer::postFrame(const QVideoFrame &f, qint64 wallMs)
{
    {
        QMutexLocker l(&m_frameMu);
        m_pending = f;
        m_pendingTime = wallMs;
    }
    if (!m_deliveryQueued.exchange(true))
        QMetaObject::invokeMethod(this, &VideoPlayer::deliverFrame, Qt::QueuedConnection);
}

void VideoPlayer::deliverFrame()
{
    m_deliveryQueued = false;
    QVideoFrame f;
    qint64 t;
    {
        QMutexLocker l(&m_frameMu);
        f = std::move(m_pending);
        m_pending = QVideoFrame();
        t = m_pendingTime;
    }
    if (!f.isValid())
        return;
    if (m_sink)
        m_sink->setVideoFrame(f);
    m_frameTime = t;
    emit frameTimeChanged();
}
