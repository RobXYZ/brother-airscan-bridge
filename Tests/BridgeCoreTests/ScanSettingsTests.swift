import XCTest
@testable import BridgeCore

final class ScanSettingsTests: XCTestCase {
    private func settings(_ body: String) -> ScanSettings? {
        ScanSettings(xml: Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <scan:ScanSettings xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03" \
            xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm">\(body)</scan:ScanSettings>
            """.utf8))
    }

    func testParsesATypicalRequest() throws {
        let parsed = try XCTUnwrap(settings("""
            <pwg:Version>2.63</pwg:Version>
            <pwg:ScanRegions><pwg:ScanRegion>
              <pwg:XOffset>0</pwg:XOffset><pwg:YOffset>30</pwg:YOffset>
              <pwg:Width>2480</pwg:Width><pwg:Height>3508</pwg:Height>
              <pwg:ContentRegionUnits>escl:ThreeHundredthsOfInches</pwg:ContentRegionUnits>
            </pwg:ScanRegion></pwg:ScanRegions>
            <pwg:InputSource>Feeder</pwg:InputSource>
            <scan:ColorMode>Grayscale8</scan:ColorMode>
            <scan:XResolution>200</scan:XResolution><scan:YResolution>200</scan:YResolution>
            <scan:Duplex>true</scan:Duplex>
            """))
        XCTAssertEqual(parsed.resolution, 200)
        XCTAssertEqual(parsed.colorMode, .gray)
        XCTAssertEqual(parsed.xOffset, 0)
        XCTAssertEqual(parsed.yOffset, 30)
        XCTAssertEqual(parsed.width, 2480)
        XCTAssertEqual(parsed.height, 3508)
        XCTAssertTrue(parsed.duplex)
    }

    func testMissingElementsAreNil() throws {
        let parsed = try XCTUnwrap(settings("<pwg:Version>2.63</pwg:Version>"))
        XCTAssertNil(parsed.resolution)
        XCTAssertNil(parsed.colorMode)
        XCTAssertNil(parsed.width)
        XCTAssertFalse(parsed.duplex)
    }

    func testRejectsMalformedXML() {
        XCTAssertNil(ScanSettings(xml: Data("<scan:ScanSettings><oops>".utf8)))
    }

    func testIgnoresAbsurdNumbers() throws {
        let parsed = try XCTUnwrap(settings("<pwg:Width>99999999999</pwg:Width>"))
        XCTAssertNil(parsed.width)
    }

    func testPlanConvertsUnitsToPixels() {
        var request = ScanSettings()
        request.resolution = 150
        request.width = 2480
        request.height = 3508
        let plan = ScanPlan(settings: request, model: .ads1100w)
        XCTAssertEqual(plan.dpi, 150)
        XCTAssertEqual(plan.width, 1240)
        XCTAssertEqual(plan.height, 1754)
        XCTAssertEqual(plan.colorMode, .color)
    }

    func testPlanDefaultsToFullWidthA4At300() {
        let plan = ScanPlan(settings: ScanSettings(), model: .ads1100w)
        XCTAssertEqual(plan.dpi, 300)
        XCTAssertEqual(plan.width, 2550)
        XCTAssertEqual(plan.height, 3508)
    }

    func testPlanClampsToTheScanArea() {
        var request = ScanSettings()
        request.resolution = 300
        request.xOffset = 2000
        request.width = 5000
        request.yOffset = -50
        request.height = 100_000
        let plan = ScanPlan(settings: request, model: .ads1100w)
        XCTAssertEqual(plan.x, 2000)
        XCTAssertEqual(plan.width, 550)
        XCTAssertEqual(plan.y, 0)
        XCTAssertEqual(plan.height, 4200)
    }

    func testPlanPicksNearestSupportedResolution() {
        var request = ScanSettings()
        request.resolution = 250
        XCTAssertEqual(ScanPlan(settings: request, model: .ads1100w).dpi, 200)
        request.resolution = 1200
        XCTAssertEqual(ScanPlan(settings: request, model: .ads1100w).dpi, 600)
    }

    func testDuplexOnlyWhenTheModelSupportsIt() {
        var request = ScanSettings()
        request.duplex = true
        XCTAssertTrue(ScanPlan(settings: request, model: .ads1100w).duplex)
    }

    func testUnpackTurnsSetBitsBlack() {
        XCTAssertEqual(Array(Imaging.unpack(Data([0b1010_0000]))),
                       [0x00, 0xFF, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
    }
}
