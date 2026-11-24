// DV stream end detection. Called serially by the capture engine, with monotonic time.
#pragma once
#include "dvmeta.h"
#include <cstring>
#include <vector>

class DvEndDetector {
    bool started = false, sawAdvancingTc = false;
    int previousTc = -1;
    double lastProgress = 0;
    std::vector<uint8_t> previous;
public:
    static constexpr int graceSeconds = 15;

    void observe(const uint8_t *frame, size_t size, const tapecap::TapeMeta &meta, double now) {
        if (size != 144000 && size != 120000) return;
        const int tc = meta.haveTc ? ((meta.tcH * 60 + meta.tcM) * 60 + meta.tcS) * 30 + meta.tcF : -1;
        const bool changedTc = tc >= 0 && tc != previousTc;
        if (changedTc && previousTc >= 0) sawAdvancingTc = true;
        if (tc >= 0) previousTc = tc;

        // Once a tape clock is established, an identical A/V payload with a
        // frozen or missing clock is consistent with a deck repeating filler.
        // Ignore ancillary packs, which can change while the picture is held.
        bool progress = !sawAdvancingTc || changedTc || previous.size() != size;
        if (!progress) {
            for (size_t i = 0; i < size; i += 80) {
                const int section = frame[i] >> 5;
                if (section != 3 && section != 4) continue;
                const size_t skip = section == 3 ? 8 : 3;
                if (std::memcmp(frame+i+skip, previous.data()+i+skip, 80-skip) != 0) {
                    progress = true;
                    break;
                }
            }
        }
        if (progress) lastProgress = now;
        previous.assign(frame, frame+size);
        started = true;
    }
    bool expired(double now) const { return started && now - lastProgress >= graceSeconds; }
};
