import Foundation

/// The colour modes eSCL clients ask for.
public enum ColorMode: String, Sendable {
    case color = "RGB24"
    case gray = "Grayscale8"
    case blackAndWhite = "BlackAndWhite1"
}

/// A client's scan request, as sent in the body of `POST /eSCL/ScanJobs`.
/// Lengths are in eSCL units (1/300 inch); nil means the client didn't say.
public struct ScanSettings: Equatable, Sendable {
    public var resolution: Int?
    public var colorMode: ColorMode?
    public var xOffset: Int?
    public var yOffset: Int?
    public var width: Int?
    public var height: Int?
    public var duplex = false

    public init() {}

    /// Parses a ScanSettings document. Unknown elements are ignored; a document that isn't
    /// well-formed XML yields nil.
    public init?(xml: Data) {
        let reader = ElementReader()
        let parser = XMLParser(data: xml)
        parser.shouldProcessNamespaces = true   // so "scan:Width" and "pwg:Width" both read as "Width"
        parser.delegate = reader
        guard parser.parse() else { return nil }

        func int(_ name: String) -> Int? {
            // Values come straight from the network: ignore anything absurd.
            reader.values[name].flatMap { Int($0) }.flatMap { abs($0) <= 1_000_000 ? $0 : nil }
        }
        resolution = int("XResolution")
        colorMode = reader.values["ColorMode"].flatMap(ColorMode.init(rawValue:))
        xOffset = int("XOffset")
        yOffset = int("YOffset")
        width = int("Width")
        height = int("Height")
        duplex = reader.values["Duplex"]?.lowercased() == "true"
    }
}

/// Collects the text of each leaf element, first occurrence wins.
private final class ElementReader: NSObject, XMLParserDelegate {
    var values: [String: String] = [:]
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty, values[name] == nil { values[name] = value }
        text = ""
    }
}

/// A scan request resolved against what the scanner can do: what to ask the scanner for, and
/// the exact size of the image to hand back to the client.
public struct ScanPlan: Equatable, Sendable {
    public let dpi: Int
    public let colorMode: ColorMode
    public let duplex: Bool
    /// Scan window in pixels at `dpi`. Pages are delivered at exactly `width` x `height`,
    /// padded with white where the scanner covers less.
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    /// A4 length, used when the client gives no height.
    static let defaultHeight = 3508

    public init(settings: ScanSettings, model: ScannerModel) {
        dpi = model.nearestResolution(to: settings.resolution ?? 300)
        colorMode = settings.colorMode ?? .color
        duplex = settings.duplex && model.duplex

        // Clamp in eSCL units first, then convert to pixels.
        let x300 = min(max(settings.xOffset ?? 0, 0), model.maxWidth - 1)
        let y300 = min(max(settings.yOffset ?? 0, 0), model.maxHeight - 1)
        let w300 = min(max(settings.width ?? model.maxWidth, 1), model.maxWidth - x300)
        let h300 = min(max(settings.height ?? Self.defaultHeight, 1), model.maxHeight - y300)
        let dpi = self.dpi
        func pixels(_ units: Int) -> Int { units * dpi / 300 }
        x = pixels(x300)
        y = pixels(y300)
        width = max(pixels(w300), 1)
        height = max(pixels(h300), 1)
    }
}
