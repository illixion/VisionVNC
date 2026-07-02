import XCTest
@testable import VisionVNC

/// The EQ model's math is what makes the editor honest: the on-screen
/// curve (RBJ biquad responses) must match what AVAudioUnitEQ plays, and
/// the Q→bandwidth conversion at the DSP boundary is the classic spot to
/// get silently wrong. These pin down both, plus persistence round-trips
/// and the draw-stroke → bands fit.
final class EQSettingsTests: XCTestCase {

    // MARK: - Frequency response

    func testParametricPeakGainAtCenter() {
        let band = EQBandSetting(frequency: 1_000, gain: 12, q: 1.41)
        // At the center frequency a peaking filter hits its full gain.
        XCTAssertEqual(EQSettings.bandResponseDB(band: band, hz: 1_000), 12, accuracy: 0.1)
    }

    func testParametricPeakFlatFarAway() {
        let band = EQBandSetting(frequency: 1_000, gain: 12, q: 1.41)
        XCTAssertEqual(EQSettings.bandResponseDB(band: band, hz: 30), 0, accuracy: 0.3)
        XCTAssertEqual(EQSettings.bandResponseDB(band: band, hz: 18_000), 0, accuracy: 0.5)
    }

    func testCutIsSymmetricToBoost() {
        let boost = EQBandSetting(frequency: 500, gain: 9, q: 2)
        let cut = EQBandSetting(frequency: 500, gain: -9, q: 2)
        for hz in [100.0, 300, 500, 900, 4_000] {
            XCTAssertEqual(EQSettings.bandResponseDB(band: boost, hz: hz),
                           -EQSettings.bandResponseDB(band: cut, hz: hz),
                           accuracy: 0.05, "asymmetric at \(hz) Hz")
        }
    }

    func testShelvesReachFullGainInStopband() {
        let low = EQBandSetting(type: .lowShelf, frequency: 100, gain: 6)
        XCTAssertEqual(EQSettings.bandResponseDB(band: low, hz: 20), 6, accuracy: 0.5)
        XCTAssertEqual(EQSettings.bandResponseDB(band: low, hz: 5_000), 0, accuracy: 0.3)

        let high = EQBandSetting(type: .highShelf, frequency: 8_000, gain: -6)
        XCTAssertEqual(EQSettings.bandResponseDB(band: high, hz: 19_000), -6, accuracy: 0.6)
        XCTAssertEqual(EQSettings.bandResponseDB(band: high, hz: 200), 0, accuracy: 0.3)
    }

    func testCombinedResponseSumsBandsAndPreamp() {
        var settings = EQSettings()
        settings.preampDB = -3
        settings.bands = [
            EQBandSetting(frequency: 100, gain: 6, q: 1.41),
            EQBandSetting(frequency: 100, gain: 6, q: 1.41),
        ]
        // Cascaded identical biquads double the dB; preamp adds on top.
        XCTAssertEqual(settings.responseDB(atHz: 100), -3 + 12, accuracy: 0.2)
    }

    // MARK: - Q → bandwidth (octaves)

    func testQToBandwidthKnownValues() {
        // bw = (2/ln2)·asinh(1/(2Q)); Q ≈ 1.414 → ~1 octave is the
        // canonical sanity point.
        XCTAssertEqual(EQSettings.bandwidthOctaves(q: 1.414), 1.0, accuracy: 0.02)
        // Narrower Q → narrower bandwidth, monotonically.
        XCTAssertLessThan(EQSettings.bandwidthOctaves(q: 10),
                          EQSettings.bandwidthOctaves(q: 1))
        XCTAssertEqual(EQSettings.bandwidthOctaves(q: 0.667), 2.0, accuracy: 0.05)
    }

    // MARK: - Persistence

    func testSaveLoadRoundTrip() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)

        var settings = EQSettings()
        settings.enabled = true
        settings.preampDB = -4.5
        settings.bands = [
            EQBandSetting(type: .lowShelf, frequency: 80, gain: 4, q: 0.71),
            EQBandSetting(frequency: 2_500, gain: -6, q: 3.2),
        ]
        settings.save(to: defaults)
        XCTAssertEqual(EQSettings.load(from: defaults), settings)
    }

    func testLoadReturnsDefaultsWhenAbsentOrCorrupt() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        XCTAssertEqual(EQSettings.load(from: defaults), EQSettings())

        defaults.set(Data("not json".utf8), forKey: EQSettings.defaultsKey)
        XCTAssertEqual(EQSettings.load(from: defaults), EQSettings())
    }

    // MARK: - Clamping

    func testClampedLimitsAllParameters() {
        let wild = EQBandSetting(frequency: 100_000, gain: 90, q: 500).clamped()
        XCTAssertEqual(wild.frequency, EQSettings.maxFrequency)
        XCTAssertEqual(wild.gain, EQSettings.gainRange)
        XCTAssertEqual(wild.q, 10)

        let tiny = EQBandSetting(frequency: 1, gain: -90, q: 0).clamped()
        XCTAssertEqual(tiny.frequency, EQSettings.minFrequency)
        XCTAssertEqual(tiny.gain, -EQSettings.gainRange)
        XCTAssertEqual(tiny.q, 0.1)
    }

    // MARK: - Draw-stroke fit

    func testFitFlatLineProducesNoBands() {
        let flat = stride(from: 20.0, through: 20_000, by: 500).map { (hz: $0, db: 0.0) }
        XCTAssertTrue(EQSettings.fit(drawnCurve: flat).isEmpty)
    }

    func testFitConstantBoostHitsEveryCenter() {
        let curve = (0..<200).map { i -> (hz: Double, db: Double) in
            let hz = 20 * pow(1_000, Double(i) / 199) // 20 Hz → 20 kHz, log-spaced
            return (hz, 6.0)
        }
        let bands = EQSettings.fit(drawnCurve: curve)
        XCTAssertEqual(bands.count, EQSettings.fitCenters.count)
        for band in bands {
            XCTAssertEqual(band.gain, 6, accuracy: 0.2, "at \(band.frequency) Hz")
        }
        // Edges become shelves so the curve holds past them.
        XCTAssertEqual(bands.first?.type, .lowShelf)
        XCTAssertEqual(bands.last?.type, .highShelf)
        XCTAssertTrue(bands.dropFirst().dropLast().allSatisfy { $0.type == .parametric })
    }

    func testFitTiltedLineIsMonotonic() {
        // Bass boost sloping down to treble cut.
        let curve = (0..<200).map { i -> (hz: Double, db: Double) in
            let t = Double(i) / 199
            return (hz: 20 * pow(1_000, t), db: 10 - 20 * t)
        }
        let bands = EQSettings.fit(drawnCurve: curve)
        let gains = bands.map(\.gain)
        XCTAssertEqual(gains, gains.sorted(by: >), "fitted gains should follow the drawn slope")
        XCTAssertGreaterThan(gains.first ?? 0, 5)
        XCTAssertLessThan(gains.last ?? 0, -5)
    }

    func testFitRespectsMaxBandsBudget() {
        XCTAssertLessThanOrEqual(EQSettings.fitCenters.count, EQSettings.maxBands)
    }

    func testFitIgnoresGarbageInput() {
        XCTAssertTrue(EQSettings.fit(drawnCurve: []).isEmpty)
        XCTAssertTrue(EQSettings.fit(drawnCurve: [(hz: -5, db: .infinity)]).isEmpty)
    }
}
