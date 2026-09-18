import XCTest
@testable import FeedRuntime

final class RuntimeModeTests: XCTestCase {
    func testTheFourValidCombinationsMapToTheFourModes() {
        let cases: [(RequestedFeatures, RuntimeMode)] = [
            (RequestedFeatures(shadow: false, v2UI: false, v2Network: false), .legacy),
            (RequestedFeatures(shadow: true, v2UI: false, v2Network: false), .mirroredShadow),
            (RequestedFeatures(shadow: false, v2UI: true, v2Network: false), .v2Presentation),
            (RequestedFeatures(shadow: false, v2UI: true, v2Network: true), .v2Full),
        ]
        for (features, expected) in cases {
            let resolution = RuntimeModeResolver.resolve(features)
            XCTAssertEqual(resolution.mode, expected)
            XCTAssertNil(resolution.rejection)
            XCTAssertTrue(resolution.isExact)
        }
    }

    func testEveryOtherCombinationResolvesToLegacyWithAReason() {
        for shadow in [true, false] {
            for v2UI in [true, false] {
                for v2Network in [true, false] {
                    let features = RequestedFeatures(shadow: shadow, v2UI: v2UI, v2Network: v2Network)
                    let resolution = RuntimeModeResolver.resolve(features)
                    let isValid = RuntimeMode.allCases.contains {
                        $0.runsShadow == shadow && $0.usesV2Presentation == v2UI && $0.ownsAcquisition == v2Network
                    }
                    if isValid {
                        XCTAssertEqual(resolution.mode.runsShadow, shadow)
                        XCTAssertEqual(resolution.mode.usesV2Presentation, v2UI)
                        XCTAssertEqual(resolution.mode.ownsAcquisition, v2Network)
                        XCTAssertNil(resolution.rejection)
                    } else {
                        XCTAssertEqual(resolution.mode, .legacy)
                        XCTAssertNotNil(resolution.rejection, "an invalid request must be recorded, not silently accepted")
                    }
                }
            }
        }
    }

    /// Shadow and acquisition ownership are mutually exclusive: a shadow run that also owns
    /// acquisition would replace the legacy producer it is supposed to compare against.
    func testNoModeBothShadowsAndOwnsAcquisition() {
        for mode in RuntimeMode.allCases {
            XCTAssertFalse(mode.runsShadow && mode.ownsAcquisition, "\(mode) is not a valid owner")
        }
    }
}
