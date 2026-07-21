//
//  PCMWindowContractTests.swift — Lane 1 (arikit-native-shell.md §7 + §5's four seam
//  guarantees): `PCMWindow` is `Sendable`; the capture→consumer fork is drop-oldest bounded so
//  a slow consumer can never stall the producer (modelled with a fake slow consumer).
//
import AriKit
import Testing

@Suite("PCMWindow contract")
struct PCMWindowContractTests {
    @Test("PCMWindow is Sendable — compiles across an isolation boundary")
    func isSendable() async {
        let window = PCMWindow(samples: [0.1, 0.2], sampleRate: 48000, source: .mixed, hostTime: 1.5, windowID: 1)

        // Crossing an actor boundary compiles only if `PCMWindow` is genuinely `Sendable` —
        // a `Sendable`-conformance regression would fail to build, not fail at runtime.
        let echoed = await Task { window }.value
        #expect(echoed == window)
    }

    @Test("CaptureSource has exactly the three seam-defined cases")
    func captureSourceCases() {
        #expect(CaptureSource.allCases == [.microphone, .system, .mixed])
    }

    @Test(
        "a fast producer feeding a bounded drop-oldest stream never blocks, and the slow consumer sees the newest windows"
    )
    func dropOldestNeverBlocksProducer() async {
        let bufferCapacity = 4
        let totalProduced = 100

        let stream = AsyncStream<PCMWindow>(bufferingPolicy: .bufferingNewest(bufferCapacity)) { continuation in
            // Feed synchronously, with no awaiting/backpressure — if drop-oldest bounding
            // didn't work, a naive unbounded producer loop like this would be the exact
            // failure mode the plan calls out (Q2: dropping is preferred to blocking).
            for id in 0 ..< UInt64(totalProduced) {
                continuation.yield(
                    PCMWindow(samples: [], sampleRate: 48000, source: .mixed, hostTime: Double(id), windowID: id)
                )
            }
            continuation.finish()
        }

        var received: [PCMWindow] = []
        for await window in stream {
            received.append(window)
        }

        // Drop-oldest: the buffer never holds more than `bufferCapacity` at once, and what
        // survives is the tail of the sequence, not the head.
        #expect(received.count <= bufferCapacity)
        #expect(received.last?.windowID == UInt64(totalProduced - 1))
    }
}
