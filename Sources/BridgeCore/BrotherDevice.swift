import CBrotherScan
import Foundation

/// One scanned side as it came off the wire.
public struct RawPage {
    public enum Format {
        case jpeg           // a complete JPEG file
        case gray8          // rows of 8-bit grey, `width` bytes each
        case blackAndWhite  // packed rows, `width` / 8 bytes each, 1 = black
    }
    public let format: Format
    public let data: Data
    /// Pixels per row as scanned; may differ slightly from what was asked for.
    public let width: Int
}

public enum ScanFailure: Error, CustomStringConvertible, Equatable {
    case noDocument
    case jam
    case busy
    case unreachable
    case cancelled
    case device(String)

    init(_ status: bs_status) {
        switch status {
        case BS_ERR_NO_PAPER: self = .noDocument
        case BS_ERR_JAM: self = .jam
        case BS_ERR_BUSY: self = .busy
        case BS_ERR_CONNECT: self = .unreachable
        case BS_ERR_CANCELLED: self = .cancelled
        default: self = .device(String(cString: bs_status_string(status)))
        }
    }

    public var description: String {
        switch self {
        case .noDocument: return "no document in the feeder"
        case .jam: return "document jam"
        case .busy: return "scanner is busy"
        case .unreachable: return "could not connect to the scanner"
        case .cancelled: return "scan cancelled"
        case .device(let text): return text
        }
    }
}

/// Talks to the scanner through the C protocol library. Each call opens its own connection.
public struct BrotherDevice {
    public let host: String

    public init(host: String) {
        self.host = host
    }

    /// The scanner sometimes refuses its scan port for a moment (just after another client,
    /// or while macOS settles Local Network access for a newly started process).
    private func open() throws -> OpaquePointer {
        var session: OpaquePointer?
        var status = bs_open(host, BS_DEFAULT_PORT, &session)
        for _ in 0..<4 where status == BS_ERR_CONNECT {
            Thread.sleep(forTimeInterval: 1)
            status = bs_open(host, BS_DEFAULT_PORT, &session)
        }
        guard status == BS_OK, let session else { throw ScanFailure(status) }
        return session
    }

    /// Runs a scan job, calling `deliver` once per side in page order. `isCancelled` is polled
    /// as data arrives; once it returns true the scanner is told to stop and `.cancelled` is
    /// thrown.
    public func scan(_ plan: ScanPlan, isCancelled: () -> Bool, deliver: (RawPage) -> Void) throws {
        let session = try open()
        defer { bs_close(session) }

        var params = bs_params()
        switch plan.colorMode {
        case .color: params.mode = BS_MODE_COLOR
        case .gray: params.mode = BS_MODE_GRAY
        case .blackAndWhite: params.mode = BS_MODE_BW
        }
        params.dpi = Int32(plan.dpi)
        params.duplex = plan.duplex
        params.left = Int32(plan.x)
        params.top = Int32(plan.y)
        params.width = Int32(plan.width)
        params.height = Int32(plan.height)

        var info = bs_scan_info()
        var status = bs_start(session, &params, &info)
        guard status == BS_OK else { throw ScanFailure(status) }

        // The two sides of a duplex sheet can arrive interleaved, so collect per page.
        var pending: [Int32: (format: RawPage.Format, data: Data)] = [:]
        var cancelSent = false
        while true {
            if !cancelSent && isCancelled() {
                bs_cancel(session)
                cancelSent = true
            }
            var event = bs_event()
            status = bs_next(session, &event)
            guard status == BS_OK else { throw ScanFailure(status) }

            switch event.type {
            case BS_EV_JOB_END:
                if cancelSent { throw ScanFailure.cancelled }
                return
            case BS_EV_DATA:
                let format: RawPage.Format =
                    event.kind == BS_DATA_JPEG ? .jpeg : event.kind == BS_DATA_GRAY8 ? .gray8 : .blackAndWhite
                var page = pending[event.page] ?? (format, Data())
                page.data.append(event.data, count: event.len)
                pending[event.page] = page
            default:   // page end
                guard let page = pending.removeValue(forKey: event.page), !cancelSent else { continue }
                deliver(RawPage(format: page.format, data: page.data, width: Int(info.width)))
            }
        }
    }
}
