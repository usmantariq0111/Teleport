import Foundation
import Network
import Darwin

/// Watches the device's network interfaces and publishes the IPv4
/// addresses other peers can reach us on (Wi-Fi, Ethernet, Tailscale,
/// etc.).
///
/// Why this exists:
///   - The host needs to tell the joiner where to connect. Without this
///     the user has to dig through `System Settings → Network` or run
///     `ifconfig` in Terminal — a non-starter for a "just works" tool.
///   - Macs commonly have several active interfaces (Wi-Fi + a virtual
///     adapter from Docker/Tailscale/Tunnelblick); we surface all of
///     them so the user can pick the one that matches the joiner's
///     network.
///   - We refresh on `NWPathMonitor` updates so toggling Wi-Fi or
///     plugging in Ethernet reflects immediately in the UI.
@MainActor
final class LocalAddressBook: ObservableObject {

    static let shared = LocalAddressBook()

    struct Address: Identifiable, Hashable {
        let interface: String   // "en0", "utun4", etc.
        let label: String       // "Wi-Fi", "Ethernet", "VPN", "Other"
        let ip: String          // dotted-quad IPv4
        var id: String { "\(interface)/\(ip)" }
    }

    @Published private(set) var addresses: [Address] = []

    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "teleport.local-address-monitor")
    private var started = false

    private init() {
        refresh()
        startMonitoring()
    }

    /// Best-guess "primary" address — the one most likely to match the
    /// joiner. Prefers Wi-Fi, then Ethernet, then anything else.
    var primary: Address? {
        addresses.first(where: { $0.label == "Wi-Fi" })
            ?? addresses.first(where: { $0.label == "Ethernet" })
            ?? addresses.first
    }

    func refresh() {
        addresses = Self.enumerateIPv4Addresses()
    }

    private func startMonitoring() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] _ in
            // NWPathMonitor fires on its own queue; bounce back to main
            // before mutating @Published state.
            DispatchQueue.main.async {
                self?.refresh()
            }
        }
        monitor.start(queue: monitorQueue)
    }

    // MARK: - Interface enumeration

    /// Calls `getifaddrs(3)` and returns every active IPv4 address,
    /// excluding loopback and link-local (169.254.x.x). The label is a
    /// rough categorisation based on the BSD-style interface name —
    /// macOS doesn't expose human-readable names without going through
    /// SystemConfiguration, which is heavyweight overkill here.
    private static func enumerateIPv4Addresses() -> [Address] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var seen = Set<String>()
        var out: [Address] = []

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ptr = cursor {
            defer { cursor = ptr.pointee.ifa_next }

            let flags = Int32(ptr.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isRunning = (flags & IFF_RUNNING) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0
            guard isUp, isRunning, !isLoopback else { continue }

            guard let sa = ptr.pointee.ifa_addr,
                  sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }

            let ifaceName = String(cString: ptr.pointee.ifa_name)

            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(sa,
                                     socklen_t(sa.pointee.sa_len),
                                     &hostBuffer,
                                     socklen_t(hostBuffer.count),
                                     nil, 0,
                                     NI_NUMERICHOST)
            guard result == 0 else { continue }
            let ip = String(cString: hostBuffer)

            // Filter out APIPA / link-local — won't route anywhere useful.
            if ip.hasPrefix("169.254.") { continue }
            if seen.contains(ip) { continue }
            seen.insert(ip)

            out.append(Address(interface: ifaceName,
                               label: friendlyLabel(for: ifaceName),
                               ip: ip))
        }

        // Sort: Wi-Fi → Ethernet → VPN → Other, then alphabetically.
        let order: [String: Int] = ["Wi-Fi": 0, "Ethernet": 1, "VPN": 2, "Other": 3]
        out.sort {
            let a = order[$0.label] ?? 99
            let b = order[$1.label] ?? 99
            if a != b { return a < b }
            return $0.interface < $1.interface
        }
        return out
    }

    private static func friendlyLabel(for iface: String) -> String {
        // BSD interface naming on macOS:
        //   en0 → Wi-Fi (typically), en1+ → Ethernet / Thunderbolt
        //   utun* → VPN tunnels (Tailscale, WireGuard, IPSec)
        //   bridge*, anpi*, llw* → various virtualisation/AWDL bits
        if iface == "en0" { return "Wi-Fi" }
        if iface.hasPrefix("en") { return "Ethernet" }
        if iface.hasPrefix("utun") { return "VPN" }
        return "Other"
    }
}
