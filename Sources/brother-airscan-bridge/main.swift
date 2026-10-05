import BridgeCore
import CryptoKit
import Foundation

// brother-airscan-bridge: makes a Brother scanner that only speaks Brother's own network
// protocol appear to macOS as an AirScan (eSCL) scanner.
//
// usage: brother-airscan-bridge [--host ADDRESS] [--port N] [--name NAME]
//        brother-airscan-bridge --discover

var host: String?
var port: UInt16 = 0
var name: String?
var discoverOnly = false

func usage(_ problem: String) -> Never {
    FileHandle.standardError.write(Data("""
        \(problem)
        usage: brother-airscan-bridge [--host ADDRESS] [--port N] [--name NAME] | --discover
          --host      scanner address; found automatically over Bonjour if omitted
          --port      port to listen on; chosen by the system if omitted
          --name      name to advertise; defaults to "<model> (AirScan)"
          --discover  look for a supported scanner, print its address and exit\n
        """.utf8))
    exit(2)
}

var arguments = CommandLine.arguments.dropFirst().makeIterator()
func value(of flag: String) -> String {
    guard let value = arguments.next(), !value.isEmpty else { usage("\(flag) needs a value") }
    return value
}
while let argument = arguments.next() {
    switch argument {
    case "--host": host = value(of: argument)
    case "--port":
        guard let number = UInt16(value(of: argument)) else { usage("--port needs a number 0-65535") }
        port = number
    case "--name": name = value(of: argument)
    case "--discover": discoverOnly = true
    default: usage("unknown argument \(argument)")
    }
}

let locator = ScannerLocator(host: host)

if discoverOnly {
    do {
        let found = try locator.scanner()
        print("\(found.model.name) at \(found.host)")
        exit(0)
    } catch {
        print(error)
        exit(1)
    }
}

// Only one model is supported so far, so its capabilities can be advertised before the
// scanner has been found (it may be switched off when the bridge starts).
let model = ScannerModel.ads1100w
let advertisedName = name ?? "\(model.name) (AirScan)"

// A stable identity per Mac and model, so macOS treats the bridge as the same device across
// restarts and two Macs running it don't clash.
let uuid: String = {
    let seed = "brother-airscan-bridge:\(ProcessInfo.processInfo.hostName):\(model.bonjourModel)"
    var bytes = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
    bytes[6] = (bytes[6] & 0x0F) | 0x50
    bytes[8] = (bytes[8] & 0x3F) | 0x80
    let hex = bytes.map { String(format: "%02x", $0) }.joined()
    return [hex.prefix(8), hex.dropFirst(8).prefix(4), hex.dropFirst(12).prefix(4),
            hex.dropFirst(16).prefix(4), hex.dropFirst(20)].joined(separator: "-")
}()

do {
    let server = ESCLServer(locator: locator, model: model, name: advertisedName, uuid: uuid, port: port)
    try server.start()
    log("bridging \(model.name) as \"\(advertisedName)\"")
    dispatchMain()
} catch {
    log("fatal: \(error)")
    exit(1)
}
