#pragma once

#include <algorithm>
#include <cstdint>

// Smooths live video from cameras that deliver frames in bursts (typically Wi-Fi)
// while keeping it at real time.
//
// It learns the smallest delay between a frame's timestamp and the moment it
// arrived from the network (the camera's best case, the "baseline") and shows each
// frame at timestamp + baseline + buffer, so frames bunched together by the network
// are spread out again. Frames that are already late are shown at once, so a viewer
// that fell behind (a busy moment, the screen locking) reads through the waiting
// video until it is back to real time.
//
// Arrival times come from a reader that takes packets off the network as soon as
// they come in, so time a frame spent waiting to be shown never looks like network
// delay. The baseline goes down at once, goes up only slowly (enough to follow a
// camera clock that runs a little slow), and is re-learned when the timestamps jump
// (the camera reconnected).
class LivePacer
{
public:
    // How long to wait (ms) before showing a frame with this timestamp that arrived
    // at arrivalMs. All times are on the same steady clock.
    int64_t wait(double ptsMs, int64_t arrivalMs, int64_t nowMs, int bufferMs)
    {
        const double offset = double(arrivalMs) - ptsMs;
        if (m_start < 0 || ptsMs < m_lastPts - 1000 || ptsMs > m_lastPts + 5000)
            restart(offset, arrivalMs); // first frame, or the timestamps jumped
        m_lastPts = ptsMs;
        m_min = std::min(m_min, offset);
        m_windowMin = std::min(m_windowMin, offset);
        if (arrivalMs - m_windowStart >= kWindowMs) {
            // A camera whose clock runs slow makes every frame look a little later:
            // follow that, a few ms per window at most.
            if (m_windowMin > m_min)
                m_min += std::min(m_windowMin - m_min, kMaxRiseMs);
            m_windowMin = offset;
            m_windowStart = arrivalMs;
        }
        // The first moments after a (re)start are the server's cached frames: play through.
        if (bufferMs <= 0 || nowMs - m_start < kSettleMs)
            return 0;
        const double due = ptsMs + m_min + bufferMs;
        return due > double(nowMs) ? int64_t(std::min(due - double(nowMs), double(bufferMs))) : 0;
    }

    static constexpr int64_t kWindowMs = 10000;
    static constexpr double kMaxRiseMs = 20; // 2 ms per second
    static constexpr int64_t kSettleMs = 1500;

private:
    void restart(double offset, int64_t arrivalMs)
    {
        m_start = arrivalMs;
        m_min = m_windowMin = offset;
        m_windowStart = arrivalMs;
    }
    int64_t m_start = -1;
    double m_min = 0, m_windowMin = 0, m_lastPts = 0;
    int64_t m_windowStart = 0;
};
