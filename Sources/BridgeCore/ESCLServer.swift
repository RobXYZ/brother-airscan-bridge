import Foundation
import Network

/// The eSCL (AirScan) face of the bridge: what macOS's built-in scanner driver talks to.
///
///   GET    /eSCL/ScannerCapabilities          what the scanner can do
///   GET    /eSCL/ScannerStatus                idle/busy, feeder loaded or empty, recent jobs
///   POST   /eSCL/ScanJobs                     start a job; reply carries its Location
///   GET    /eSCL/ScanJobs/{id}/NextDocument   next page, or 404 when there are no more
///   DELETE /eSCL/ScanJobs/{id}                cancel
public final class ESCLServer {
    private let locator: ScannerLocator
    private let model: ScannerModel
    private let name: String
    private let uuid: String
    private let port: UInt16
    private var http: HTTPServer?

    private enum JobState: String {
        case processing = "Processing", completed = "Completed", canceled = "Canceled", aborted = "Aborted"
    }

    private final class Job {
        let id = UUID().uuidString.lowercased()
        var state = JobState.processing
        var ready: [Data] = []      // scanned pages the client hasn't fetched yet
        var scanned = 0
        var delivered = 0
        var cancelRequested = false
        var failure: ScanFailure?
        var finishedAt: Date?
    }

    /// Guards everything below; also signalled whenever a job gains a page or changes state.
    private let condition = NSCondition()
    private var jobs: [String: Job] = [:]
    private var busy = false
    private var feederEmptyUntil = Date.distantPast

    /// Finished jobs stay listed this long so clients can read their final state.
    private static let jobRetention: TimeInterval = 300
    /// Asking the scanner whether paper is loaded takes a couple of seconds and a connection
    /// to its scan port, and clients poll status constantly, so the feeder is reported as
    /// loaded until the scanner refuses a job for lack of paper. That refusal is immediate, and
    /// "empty" is then reported for this long so the client can tell the user why.
    private static let feederEmptyReportTime: TimeInterval = 15

    public init(locator: ScannerLocator, model: ScannerModel, name: String, uuid: String, port: UInt16) {
        self.locator = locator
        self.model = model
        self.name = name
        self.uuid = uuid
        self.port = port
    }

    public func start() throws {
        let txt: [String: String] = [
            "txtvers": "1", "vers": "2.63", "rs": "eSCL", "ty": name, "uuid": uuid,
            "pdl": "image/jpeg", "cs": "color,grayscale,binary",
            "is": [model.hasFlatbed ? "platen" : nil, model.hasFeeder ? "adf" : nil].compactMap { $0 }.joined(separator: ","),
            "duplex": model.duplex ? "T" : "F", "note": "", "representation": "",
        ]
        let service = NWListener.Service(name: name, type: "_uscan._tcp", txtRecord: NWTXTRecord(txt))
        let server = try HTTPServer(port: port, service: service) { [unowned self] in self.handle($0) }
        server.start()
        http = server
    }

    // MARK: - Routing

    private func handle(_ request: HTTPRequest) -> HTTPResponse {
        let parts = request.path.split(separator: "/").map(String.init)
        guard parts.first == "eSCL" else { return .status(404) }
        let rest = Array(parts.dropFirst())
        if !(request.method == "GET" && rest == ["ScannerStatus"]) {
            log("\(request.method) \(request.path)")   // status polls would drown the log
        }
        switch (request.method, rest.count) {
        case ("GET", 1) where rest[0] == "ScannerCapabilities": return .xml(capabilities())
        case ("GET", 1) where rest[0] == "ScannerStatus": return .xml(status())
        case ("POST", 1) where rest[0] == "ScanJobs": return createJob(request.body)
        case ("GET", 3) where rest[0] == "ScanJobs" && rest[2] == "NextDocument": return nextDocument(rest[1])
        case ("DELETE", 2) where rest[0] == "ScanJobs": return cancel(rest[1])
        default: return .status(404)
        }
    }

    // MARK: - Jobs

    private func createJob(_ body: Data) -> HTTPResponse {
        guard let settings = ScanSettings(xml: body) else { return .status(400) }
        let plan = ScanPlan(settings: settings, model: model)

        condition.lock()
        if busy {
            condition.unlock()
            return .status(503)
        }
        busy = true
        pruneJobs()
        let job = Job()
        jobs[job.id] = job
        condition.unlock()

        log("job \(job.id): \(plan.dpi) dpi \(plan.colorMode.rawValue)\(plan.duplex ? " duplex" : "") "
            + "\(plan.width)x\(plan.height) at \(plan.x),\(plan.y)")
        DispatchQueue.global().async { self.run(job, plan) }
        return HTTPResponse(status: 201, headers: [("Location", "/eSCL/ScanJobs/\(job.id)")])
    }

    /// Scans on a background queue, handing each page to the job as soon as it is complete so
    /// the client can fetch it while the next sheet feeds.
    private func run(_ job: Job, _ plan: ScanPlan) {
        var failure: ScanFailure?
        do {
            let device = BrotherDevice(host: try locator.scanner().host)
            try device.scan(plan, isCancelled: {
                self.condition.lock()
                defer { self.condition.unlock() }
                return job.cancelRequested
            }, deliver: { page in
                guard let jpeg = Imaging.jpeg(from: page, plan: plan) else {
                    log("job \(job.id): page could not be decoded, skipped")
                    return
                }
                self.condition.lock()
                job.ready.append(jpeg)
                job.scanned += 1
                self.condition.broadcast()
                self.condition.unlock()
            })
        } catch let error as ScanFailure {
            failure = error
            if error == .unreachable { locator.forget() }
        } catch {
            failure = .device("\(error)")
        }

        condition.lock()
        job.failure = failure
        switch failure {
        case nil: job.state = .completed
        case .cancelled: job.state = .canceled
        default: job.state = .aborted
        }
        job.finishedAt = Date()
        busy = false
        feederEmptyUntil = failure == .noDocument
            ? Date().addingTimeInterval(Self.feederEmptyReportTime) : .distantPast
        condition.broadcast()
        condition.unlock()
        log("job \(job.id): \(failure.map { "\($0)" } ?? "finished"), \(job.scanned) page(s)")
    }

    /// Waits for the job's next page. 404 tells the client there are no more.
    private func nextDocument(_ id: String) -> HTTPResponse {
        condition.lock()
        defer { condition.unlock() }
        guard let job = jobs[id] else { return .status(404) }
        while job.ready.isEmpty && job.state == .processing && !job.cancelRequested { condition.wait() }
        guard !job.ready.isEmpty, !job.cancelRequested else { return .status(404) }
        job.delivered += 1
        return HTTPResponse(status: 200, headers: [("Content-Type", "image/jpeg")], body: job.ready.removeFirst())
    }

    private func cancel(_ id: String) -> HTTPResponse {
        condition.lock()
        defer { condition.unlock() }
        guard let job = jobs[id] else { return .status(404) }
        // The scan thread sees the flag and stops the scanner; anyone waiting in NextDocument is
        // released straight away rather than when the scanner has wound down.
        job.cancelRequested = true
        job.ready.removeAll()
        condition.broadcast()
        return .status(200)
    }

    /// Call with `condition` held.
    private func pruneJobs() {
        let cutoff = Date().addingTimeInterval(-Self.jobRetention)
        jobs = jobs.filter { $0.value.finishedAt.map { $0 > cutoff } ?? true }
    }

    // MARK: - Status

    private func status() -> String {
        condition.lock()
        defer { condition.unlock() }
        pruneJobs()
        let adfState = busy ? "ScannerAdfProcessing"
            : Date() < feederEmptyUntil ? "ScannerAdfEmpty" : "ScannerAdfLoaded"
        let jobInfo = jobs.values.map { job in
            let reason: String
            switch job.state {
            case .processing: reason = "JobScanning"
            case .completed: reason = "JobCompletedSuccessfully"
            case .canceled: reason = "JobCanceledByUser"
            case .aborted: reason = "AbortedBySystem"
            }
            return """
            <scan:JobInfo>
              <pwg:JobUri>/eSCL/ScanJobs/\(job.id)</pwg:JobUri>
              <pwg:JobUuid>\(job.id)</pwg:JobUuid>
              <scan:Age>\(Int(Date().timeIntervalSince(job.finishedAt ?? Date())))</scan:Age>
              <pwg:ImagesCompleted>\(job.scanned)</pwg:ImagesCompleted>
              <pwg:ImagesToTransfer>\(job.ready.count)</pwg:ImagesToTransfer>
              <pwg:JobState>\(job.state.rawValue)</pwg:JobState>
              <pwg:JobStateReasons><pwg:JobStateReason>\(reason)</pwg:JobStateReason></pwg:JobStateReasons>
            </scan:JobInfo>
            """
        }.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <scan:ScannerStatus \(Self.namespaces)>
          <pwg:Version>2.63</pwg:Version>
          <pwg:State>\(busy ? "Processing" : "Idle")</pwg:State>
          \(model.hasFeeder ? "<scan:AdfState>\(adfState)</scan:AdfState>" : "")
          <scan:Jobs>\(jobInfo)</scan:Jobs>
        </scan:ScannerStatus>
        """
    }

    // MARK: - Capabilities

    private static let namespaces = """
        xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03" \
        xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm"
        """

    private func inputCaps(_ element: String) -> String {
        let resolutions = model.resolutions.map {
            "<scan:DiscreteResolution><scan:XResolution>\($0)</scan:XResolution>"
                + "<scan:YResolution>\($0)</scan:YResolution></scan:DiscreteResolution>"
        }.joined()
        let maxResolution = model.resolutions.max() ?? 300
        return """
        <scan:\(element)>
          <scan:MinWidth>16</scan:MinWidth><scan:MaxWidth>\(model.maxWidth)</scan:MaxWidth>
          <scan:MinHeight>16</scan:MinHeight><scan:MaxHeight>\(model.maxHeight)</scan:MaxHeight>
          <scan:MaxScanRegions>1</scan:MaxScanRegions>
          <scan:SettingProfiles><scan:SettingProfile>
            <scan:ColorModes>
              <scan:ColorMode>RGB24</scan:ColorMode>
              <scan:ColorMode>Grayscale8</scan:ColorMode>
              <scan:ColorMode>BlackAndWhite1</scan:ColorMode>
            </scan:ColorModes>
            <scan:DocumentFormats>
              <pwg:DocumentFormat>image/jpeg</pwg:DocumentFormat>
              <scan:DocumentFormatExt>image/jpeg</scan:DocumentFormatExt>
            </scan:DocumentFormats>
            <scan:SupportedResolutions><scan:DiscreteResolutions>\(resolutions)</scan:DiscreteResolutions></scan:SupportedResolutions>
          </scan:SettingProfile></scan:SettingProfiles>
          <scan:SupportedIntents>
            <scan:Intent>Document</scan:Intent><scan:Intent>TextAndGraphic</scan:Intent>
            <scan:Intent>Photo</scan:Intent><scan:Intent>Preview</scan:Intent>
          </scan:SupportedIntents>
          <scan:MaxOpticalXResolution>\(maxResolution)</scan:MaxOpticalXResolution>
          <scan:MaxOpticalYResolution>\(maxResolution)</scan:MaxOpticalYResolution>
        </scan:\(element)>
        """
    }

    private func capabilities() -> String {
        var sources = ""
        if model.hasFlatbed {
            sources += "<scan:Platen>\(inputCaps("PlatenInputCaps"))</scan:Platen>"
        }
        if model.hasFeeder {
            sources += """
            <scan:Adf>
              \(inputCaps("AdfSimplexInputCaps"))
              \(model.duplex ? inputCaps("AdfDuplexInputCaps") : "")
              <scan:FeederCapacity>\(model.feederCapacity)</scan:FeederCapacity>
              <scan:AdfOptions>
                \(model.duplex ? "<scan:AdfOption>Duplex</scan:AdfOption>" : "")
              </scan:AdfOptions>
            </scan:Adf>
            """
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <scan:ScannerCapabilities \(Self.namespaces)>
          <pwg:Version>2.63</pwg:Version>
          <pwg:MakeAndModel>\(Self.escape(model.name))</pwg:MakeAndModel>
          <pwg:SerialNumber>\(uuid.prefix(8))</pwg:SerialNumber>
          <scan:UUID>\(uuid)</scan:UUID>
          \(sources)
        </scan:ScannerCapabilities>
        """
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
