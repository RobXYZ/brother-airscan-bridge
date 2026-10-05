/// What differs between Brother scanner models, kept in one place so that supporting another
/// model means adding a profile rather than touching the protocol or server code.
public struct ScannerModel: Sendable {
    /// Name shown to users, e.g. in Image Capture's device list.
    public let name: String
    /// The `mdl` value the scanner advertises over Bonjour.
    public let bonjourModel: String
    public let resolutions: [Int]
    /// Largest scan area, in eSCL units (1/300 inch).
    public let maxWidth: Int
    public let maxHeight: Int
    public let hasFlatbed: Bool
    public let hasFeeder: Bool
    public let duplex: Bool
    public let feederCapacity: Int

    public static let ads1100w = ScannerModel(
        name: "Brother ADS-1100W",
        bonjourModel: "ADS-1100W",
        resolutions: [100, 150, 200, 300, 400, 600],
        maxWidth: 2550,     // 8.5"
        maxHeight: 4200,    // 14"
        hasFlatbed: false,
        hasFeeder: true,
        duplex: true,
        feederCapacity: 20)

    public static let all = [ads1100w]

    public func nearestResolution(to dpi: Int) -> Int {
        resolutions.min { abs($0 - dpi) < abs($1 - dpi) } ?? 300
    }
}
