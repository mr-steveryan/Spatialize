import os

/// Interleaved-stereo ring buffer between the tap's IO thread and the engine's render thread.
// shortcut: unfair lock held briefly on two audio threads; switch to a lock-free SPSC ring (Atomic, macOS 15+) if glitches show up.
final class Ring: @unchecked Sendable {
    struct Stats: Equatable { var underruns = 0; var overruns = 0 }
    private struct State { var readPos = 0; var count = 0; var priming = true; var stats = Stats() }

    private let capacity: Int  // frames
    private let primeFrames: Int
    private let buf: UnsafeMutablePointer<Float>
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(capacityFrames: Int, primeFrames: Int) {
        precondition(capacityFrames > 0 && primeFrames > 0 && primeFrames <= capacityFrames)
        capacity = capacityFrames
        self.primeFrames = primeFrames
        buf = .allocate(capacity: capacityFrames * 2)
        buf.initialize(repeating: 0, count: capacityFrames * 2)
    }

    deinit { buf.deallocate() }

    /// Appends interleaved stereo frames, dropping the oldest on overflow.
    func write(_ src: UnsafePointer<Float>, frameCount: Int) {
        state.withLockUnchecked { s in
            var src = src, n = frameCount
            if n > capacity { src += (n - capacity) * 2; n = capacity }
            let overflow = s.count + n - capacity
            if overflow > 0 {
                s.readPos = (s.readPos + overflow) % capacity
                s.count -= overflow
                s.stats.overruns += 1
            }
            var w = (s.readPos + s.count) % capacity
            for i in 0..<n {
                buf[w * 2] = src[i * 2]
                buf[w * 2 + 1] = src[i * 2 + 1]
                w = (w + 1) % capacity
            }
            s.count += n
            if s.priming && s.count >= primeFrames { s.priming = false }
        }
    }

    /// Reads frames deinterleaved. On underrun outputs silence and waits to re-prime.
    func read(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frameCount n: Int) {
        state.withLockUnchecked { s in
            if s.priming || s.count < n {
                if !s.priming { s.stats.underruns += 1; s.priming = true }
                left.update(repeating: 0, count: n)
                right.update(repeating: 0, count: n)
                return
            }
            var r = s.readPos
            for i in 0..<n {
                left[i] = buf[r * 2]
                right[i] = buf[r * 2 + 1]
                r = (r + 1) % capacity
            }
            s.readPos = r
            s.count -= n
        }
    }

    var stats: Stats { state.withLock { $0.stats } }
}
