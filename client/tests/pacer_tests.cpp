// Simulates the live pacer against cameras and viewers that misbehave in the ways
// seen in practice, and checks that live video always returns to real time.
// Build and run: cmake --build build --target pacer_tests && build/pacer_tests
#include "../src/LivePacer.h"

#include <cstdio>
#include <functional>
#include <random>
#include <vector>

static int failures = 0;
static void check(bool ok, const char *what, double got)
{
    std::printf("%s %-62s %.0f\n", ok ? "ok  " : "FAIL", what, got);
    if (!ok)
        ++failures;
}

struct Camera {
    double fps = 30;
    double clockRate = 1.0;  // stream timestamps per real second
    double base = 400;       // best-case delay from capture to arrival (ms)
    double jitterMs = 40;    // extra random delay per frame
    double burstMs = 0;      // frames held back and released together every burstMs
    double ptsJumpAt = -1;   // real time (ms) when the timestamps restart from 0
};

struct Result {
    std::vector<double> lag;   // ms behind real time when each frame is shown
    std::vector<double> shown; // when each frame is shown (ms)
};

// stallAt/stallMs: the viewer stops reading for a while (busy, screen locked).
static Result run(const Camera &cam, int bufferMs, double seconds, double stallAt = -1, double stallMs = 0,
                  double costMs = 8)
{
    std::mt19937 rng(7);
    std::uniform_real_distribution<double> jit(0, cam.jitterMs);
    LivePacer pacer;
    Result r;
    const double step = 1000.0 / cam.fps;
    double now = 0, ptsBase = 0;
    bool jumped = false, stalled = false;
    for (int k = 0;; ++k) {
        const double captured = k * step; // real time the frame was taken
        if (captured > seconds * 1000)
            break;
        double arrival = captured + cam.base + jit(rng);
        if (cam.burstMs > 0)
            arrival = std::ceil(arrival / cam.burstMs) * cam.burstMs;
        if (cam.ptsJumpAt >= 0 && !jumped && captured >= cam.ptsJumpAt) {
            jumped = true;
            ptsBase = -captured * cam.clockRate; // timestamps start again from 0
        }
        const double pts = ptsBase + captured * cam.clockRate;
        now = std::max(now, arrival); // wait for the frame to arrive
        if (stallAt >= 0 && !stalled && now >= stallAt) {
            stalled = true;
            now += stallMs;
        }
        now += pacer.wait(pts, int64_t(arrival), int64_t(now), bufferMs);
        r.lag.push_back(now - captured - cam.base);
        r.shown.push_back(now);
        now += costMs; // decoding and drawing
    }
    return r;
}

// Largest lag over the frames shown during the last `ms` of the run.
static double tailLag(const Result &r, double ms)
{
    double worst = 0;
    const double end = r.shown.back();
    for (size_t i = 0; i < r.lag.size(); ++i)
        if (r.shown[i] >= end - ms)
            worst = std::max(worst, r.lag[i]);
    return worst;
}

int main()
{
    for (int buffer : {150, 600, 2500}) {
        char name[96];
        const double allowed = buffer + 120; // buffer + jitter + decoding

        Camera wired;
        std::snprintf(name, sizeof name, "steady camera stays live (buffer %d ms)", buffer);
        check(tailLag(run(wired, buffer, 120), 100000) <= allowed, name, tailLag(run(wired, buffer, 120), 100000));

        // The reported fault: after a pause the viewer stayed 5-14 s behind for good.
        for (double stall : {3000.0, 12000.0, 40000.0}) {
            Result r = run(wired, buffer, 300, 60000, stall);
            std::snprintf(name, sizeof name, "catches up after a %.0f s pause (buffer %d ms)", stall / 1000, buffer);
            check(tailLag(r, 120000) <= allowed, name, tailLag(r, 120000));
        }

        Camera reconnect;
        reconnect.ptsJumpAt = 90000;
        Result r = run(reconnect, buffer, 300, 89000, 8000);
        std::snprintf(name, sizeof name, "reconnect during a backlog (buffer %d ms)", buffer);
        check(tailLag(r, 120000) <= allowed, name, tailLag(r, 120000));

        // Camera clocks that run fast or slow must never build up delay.
        for (double rate : {0.999, 1.001, 0.7}) {
            Camera c;
            c.clockRate = rate;
            Result rr = run(c, buffer, 1800);
            std::snprintf(name, sizeof name, "camera clock at %.3fx for 30 min (buffer %d ms)", rate, buffer);
            check(tailLag(rr, 600000) <= allowed + (rate > 1 ? 2000 : 0), name, tailLag(rr, 600000));
        }
    }

    // Smoothing still works: Wi-Fi frames released in 400 ms bursts come out evenly.
    Camera wifi;
    wifi.burstMs = 400;
    wifi.jitterMs = 0;
    Result r = run(wifi, 600, 120, -1, 0, 2);
    int uneven = 0, n = 0;
    for (size_t i = 1; i < r.shown.size(); ++i) {
        if (r.shown[i] < 10000)
            continue;
        ++n;
        if (std::abs((r.shown[i] - r.shown[i - 1]) - 1000.0 / wifi.fps) > 15)
            ++uneven;
    }
    check(uneven * 100 <= n * 5, "Wi-Fi bursts are spread out evenly (% uneven frames)", 100.0 * uneven / n);
    check(tailLag(r, 100000) <= 600 + 450, "and stay within the buffer", tailLag(r, 100000));

    std::printf(failures ? "\n%d FAILED\n" : "\nall passed\n", failures);
    return failures ? 1 : 0;
}
