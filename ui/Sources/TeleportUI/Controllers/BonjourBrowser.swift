import Foundation
import Network

/// Browses the LAN for `_teleport._tcp` services advertised by other
/// Teleport hosts and exposes them as a live `[DiscoveredPeer]` list.
///
/// Why two APIs (NWBrowser + NetService)?
///   * `NWBrowser` is Apple's modern Network-framework browser — concurrency-
///     friendly, no need for run-loop fiddling, and its result handlers
///     publish endpoint changes incrementally.
///   * Sadly, `NWBrowser`'s `NWEndpoint.service` doesn't directly hand us
///     an IP/port, and Teleport's daemon CLI takes `<ip> --port N`, not a
///     service name. So when the user picks a peer we fall back to
///     `NetService.resolve(withTimeout:)` to get back to a hostname /
///     numeric IP that we can pass through.
///
/// We only run the browser while the dashboard is in "Join" mode — no
/// reason to keep listening when the user is hosting or idle.
@MainActor
final class BonjourBrowser: ObservableObject {

    static let shared = BonjourBrowser()

    struct DiscoveredPeer: Identifiable, Hashable {
        let id: String         // service-instance fully-qualified name
        let displayName: String
        let serviceName: String
        let domain: String
        let txtVersion: String?
    }

    @Published private(set) var peers: [DiscoveredPeer] = []
    @Published private(set) var isBrowsing: Bool = false

    private var browser: NWBrowser?

    /// Start browsing if not already.
    func start() {
        guard browser == nil else { return }
        let params = NWParameters()
        params.includePeerToPeer = true
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(type: "_teleport._tcp", domain: nil)
        let b = NWBrowser(for: descriptor, using: params)

        b.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                switch state {
                case .ready, .setup:
                    self.isBrowsing = true
                case .failed, .cancelled:
                    self.isBrowsing = false
                default:
                    break
                }
            }
        }

        b.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor [weak self] in
                self?.applyResults(results)
            }
        }

        b.start(queue: .main)
        browser = b
    }

    func stop() {
        browser?.cancel()
        browser = nil
        peers.removeAll()
        isBrowsing = false
    }

    /// Resolve a discovered peer to a hostname / IP and port suitable for
    /// `daemon ... join <ip>`. Uses the legacy `NetService.resolve()` API
    /// because `NWConnection` doesn't expose the resolved address back to
    /// the caller.
    ///
    /// The delegate keeps a reference to the `NetService` so the service
    /// (and therefore the delegate) stays alive until resolution completes
    /// or times out — and explicitly clears it on completion to avoid the
    /// associated-object retain leak the previous implementation had.
    func resolve(_ peer: DiscoveredPeer, completion: @escaping (Result<(host: String, port: Int), Error>) -> Void) {
        let service = NetService(domain: peer.domain, type: "_teleport._tcp.", name: peer.serviceName)
        let resolver = NetServiceResolverDelegate(service: service, completion: completion)
        service.delegate = resolver
        service.schedule(in: .main, forMode: .common)
        service.resolve(withTimeout: 5)
    }

    // MARK: - Private

    private func applyResults(_ results: Set<NWBrowser.Result>) {
        var next: [DiscoveredPeer] = []
        for result in results {
            guard case let .service(name: name, type: _, domain: domain, interface: _) = result.endpoint else {
                continue
            }
            var version: String?
            if case let .bonjour(record) = result.metadata {
                if case let .string(value) = record.getEntry(for: "v") {
                    version = value
                }
            }
            let id = "\(name).\(domain)"
            next.append(DiscoveredPeer(
                id: id,
                displayName: friendlyName(from: name),
                serviceName: name,
                domain: domain,
                txtVersion: version
            ))
        }
        // Stable order so SwiftUI doesn't reshuffle the list every tick.
        peers = next.sorted { $0.displayName.lowercased() < $1.displayName.lowercased() }
    }

    private func friendlyName(from instance: String) -> String {
        // Daemon advertises as "Teleport @ <hostname>".
        if let range = instance.range(of: "@ ") {
            return String(instance[range.upperBound...])
        }
        return instance
    }
}

/// One-shot delegate that bridges `NetService.resolve` callbacks into a
/// completion closure.
///
/// Lifetime: the delegate retains its `NetService` and the service retains
/// the delegate (via `service.delegate = self`). This forms a deliberate
/// cycle that keeps the resolution alive while it's in flight; we break
/// the cycle in `finish()` once the callback fires or the resolve is
/// stopped. Without an explicit break the previous version leaked a
/// closure per resolution via `objc_setAssociatedObject`.
private final class NetServiceResolverDelegate: NSObject, NetServiceDelegate {
    private var service: NetService?
    private let completion: (Result<(host: String, port: Int), Error>) -> Void
    private var done = false

    init(service: NetService,
         completion: @escaping (Result<(host: String, port: Int), Error>) -> Void) {
        self.service = service
        self.completion = completion
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        if let ip = Self.firstIPv4Address(in: sender) {
            finish(.success((host: ip, port: sender.port)))
            return
        }
        if let host = sender.hostName, !host.isEmpty {
            let trimmed = host.hasSuffix(".") ? String(host.dropLast()) : host
            finish(.success((host: trimmed, port: sender.port)))
            return
        }
        finish(.failure(NSError(domain: "Teleport.Bonjour", code: -1,
                                userInfo: [NSLocalizedDescriptionKey: "Could not resolve peer address."])))
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        let code = errorDict[NetService.errorCode] ?? 0
        finish(.failure(NSError(domain: "Teleport.Bonjour", code: code.intValue,
                                userInfo: [NSLocalizedDescriptionKey: "Bonjour resolution failed (code \(code))."])))
    }

    private func finish(_ result: Result<(host: String, port: Int), Error>) {
        guard !done else { return }
        done = true
        completion(result)
        // Break the retain cycle. After this point the delegate and the
        // service can be deallocated.
        service?.stop()
        service?.delegate = nil
        service = nil
    }

    private static func firstIPv4Address(in service: NetService) -> String? {
        guard let addresses = service.addresses else { return nil }
        for data in addresses {
            let parsed = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> String? in
                guard let sa = raw.baseAddress?.assumingMemoryBound(to: sockaddr.self) else { return nil }
                if sa.pointee.sa_family == sa_family_t(AF_INET) {
                    var addr = raw.baseAddress!.assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
                    var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    if inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil {
                        return String(cString: buf)
                    }
                }
                return nil
            }
            if let ip = parsed { return ip }
        }
        return nil
    }
}
