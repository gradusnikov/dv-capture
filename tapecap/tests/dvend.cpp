// c++ -std=c++14 tests/dvend.cpp -o /tmp/test-dvend && /tmp/test-dvend
#include "../src/dvend.h"
#include <cassert>

int main() {
    for (size_t size : {120000, 144000}) {
        std::vector<uint8_t> frame(size);
        frame[480] = 3 << 5;
        frame[560] = 4 << 5;
        DvEndDetector end;
        tapecap::TapeMeta tc;
        assert(!end.expired(100)); // Waiting for initial playback
        tc.haveTc = true;
        for (int i = 0; i < 60; ++i) {
            tc.tcS = i % 20; // includes timecode resets, static picture and silence
            end.observe(frame.data(),size,tc,i);
            assert(!end.expired(i));
        }
        assert(!end.expired(73.9));
        assert(end.expired(74)); // No further frames
        end.observe(frame.data(),size,tc,74);
        assert(end.expired(74)); // Deck continues outputting the same frame
        tc.haveTc = false;
        frame[100]++; // Ancillary changes do not count as new footage
        end.observe(frame.data(),size,tc,75);
        assert(end.expired(75));
        frame[570]++;
        end.observe(frame.data(),size,tc,76);
        assert(!end.expired(90)); // Moving video without timecode
        frame[490]++;
        end.observe(frame.data(),size,tc,90);
        assert(!end.expired(104)); // Changing audio with a static picture
        assert(end.expired(105));
        end = DvEndDetector();
        for (int i = 0; i < 45; ++i) {
            end.observe(frame.data(),size,tc,i);
            assert(!end.expired(i)); // Never had a clock, still receiving frames
        }
    }
}
