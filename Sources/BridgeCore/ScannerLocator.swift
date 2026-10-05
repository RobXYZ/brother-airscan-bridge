import dnssd
import Foundation
import Network

/// Finds the scanner on the local network through its own Bonjour advertisement
/// (`_scanner._tcp`, with the model in the `mdl` TXT key), so the bridge keeps working when
/// DHCP gives the scanner a new address.
public final class ScannerLocator {
    public struct Found {
        public let model: ScannerModel
        public let host: String
    }

    private let fixedHost: String?
    private let lock = NSLock()
    private var cached: Found?

    /// With `host` set, discovery is skipped and that address is always used.
    public init(host: String? = nil) {
        fixedHost = host
    }

    public struct NotFound: Error, CustomStringConvertible {
        public var description: String { "no supported Brother scanner found on the network" }
    }

    /// The scanner's current address. The last answer is reused until `forget()` is called.
    public func scanner() throws -> Found {
        lock.lock()
        defer { lock.unlock() }
        if let fixedHost { return Found(model: .ads1100w, host: fixedHost) }
        if let cached { return cached }
        guard let found = Self.browse(timeout: 4) else { throw NotFound() }
        log("found \(found.model.name) at \(found.host)")
        cached = found
        return found
    }

    /// Call after a connection failure so the next lookup searches again.
    public func forget() {
        lock.lock()
        cached = nil
        lock.unlock()
    }

    /// Browses for scanners and resolves the first supported one to its current address.
    static func browse(timeout: TimeInterval) -> Found? {
        let queue = DispatchQueue(label: "locator")
        let done = DispatchSemaphore(value: 0)
        var match: (model: ScannerModel, name: String, type: String, domain: String)?

        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_scanner._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { results, _ in
            for item in results where match == nil {
                guard case .bonjour(let txt) = item.metadata, let advertised = txt["mdl"],
                      let model = ScannerModel.all.first(where: { $0.bonjourModel == advertised }),
                      case .service(let name, let type, let domain, _) = item.endpoint
                else { continue }
                match = (model, name, type, domain)
                done.signal()
            }
        }
        browser.start(queue: queue)
        _ = done.wait(timeout: .now() + timeout)
        let found = queue.sync { () -> (model: ScannerModel, name: String, type: String, domain: String)? in
            browser.cancel()
            return match
        }
        guard let found, let host = resolve(name: found.name, type: found.type, domain: found.domain,
                                            timeout: timeout) else { return nil }
        // Looking the name up costs seconds each time (the resolver also waits for an IPv6
        // answer the scanner never gives), so pin it to its IPv4 address now.
        return Found(model: found.model, host: ipv4Address(of: host) ?? host)
    }

    static func ipv4Address(of host: String) -> String? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else { return nil }
        defer { freeaddrinfo(list) }
        var text = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(first.pointee.ai_addr, first.pointee.ai_addrlen, &text, socklen_t(text.count),
                          nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        return String(cString: text)
    }

    /// Looks up the host name behind a Bonjour service. This deliberately doesn't connect to
    /// the service: the scanner accepts one client at a time on its scan port and would
    /// answer "busy" to whoever came next.
    static func resolve(name: String, type: String, domain: String, timeout: TimeInterval) -> String? {
        final class Box { var host: String? }
        let box = Box()
        let callback: DNSServiceResolveReply = { _, _, _, error, _, hostTarget, _, _, _, context in
            guard error == kDNSServiceErr_NoError, let hostTarget, let context else { return }
            Unmanaged<Box>.fromOpaque(context).takeUnretainedValue().host = String(cString: hostTarget)
        }
        var service: DNSServiceRef?
        guard DNSServiceResolve(&service, 0, 0, name, type, domain, callback,
                                Unmanaged.passUnretained(box).toOpaque()) == kDNSServiceErr_NoError,
              let service else { return nil }
        defer { DNSServiceRefDeallocate(service) }

        var descriptor = pollfd(fd: DNSServiceRefSockFD(service), events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, Int32(timeout * 1000)) > 0 else { return nil }
        DNSServiceProcessResult(service)
        return box.host
    }
}
