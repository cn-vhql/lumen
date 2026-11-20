import Foundation
import SystemConfiguration

/// Snapshot of the system HTTP/HTTPS/SOCKS proxy configuration.
struct ProxyState: Equatable {
    var httpEnabled = false
    var httpsEnabled = false
    var socksEnabled = false
    var server: String?
    var port: Int?
    /// Human-readable name of the network service being reported (e.g. "Ethernet").
    var serviceName: String = ""

    var isEnabled: Bool { httpEnabled || httpsEnabled || socksEnabled }

    var endpoint: String {
        guard let server, !server.isEmpty else { return "未设置服务器" }
        if let port { return "\(server):\(port)" }
        return server
    }

    /// Which protocols the current state actually covers, for the menu subtitle.
    var protocolSummary: String {
        var parts: [String] = []
        if httpEnabled { parts.append("HTTP") }
        if httpsEnabled { parts.append("HTTPS") }
        if socksEnabled { parts.append("SOCKS") }
        return parts.isEmpty ? "未启用" : parts.joined(separator: " + ")
    }

    /// True when all three protocols are in the requested state. `isEnabled` alone
    /// would be satisfied by the first protocol the system flips, while the other
    /// two are still mid-write.
    func allProtocolsMatch(_ enabled: Bool) -> Bool {
        httpEnabled == enabled && httpsEnabled == enabled && socksEnabled == enabled
    }
}

/// Turns the system proxy on and off.
///
/// Reading uses SystemConfiguration in-process (fast, ~1 ms). Writing has to shell
/// out to `networksetup`: `SCPreferencesCommitChanges` silently refuses to commit
/// proxy changes from a non-root process, while `networksetup` succeeds without a
/// password because the `system.preferences.network` right is pre-authorised for
/// the admin group.
final class ProxyController {

    static let shared = ProxyController()

    /// `networksetup` lives here; the absolute path avoids relying on PATH.
    private static let networksetup = "/usr/sbin/networksetup"

    /// Proxy writes take ~75 ms per protocol, so they run off the main thread.
    private let queue = DispatchQueue(label: "local.lumen.proxy")

    private(set) var state: ProxyState

    private init() {
        state = ProxyController.readState()
    }

    // MARK: - Reading

    /// Reads the live proxy state without spawning a subprocess.
    static func readState() -> ProxyState {
        var state = ProxyState()
        let serviceID = primaryServiceID()
        state.serviceName = serviceID.flatMap { serviceName(for: $0) } ?? ""

        // The live switches come from the global proxy dict.
        if let proxies = SCDynamicStoreCopyProxies(nil) as? [String: Any] {
            state.httpEnabled = (proxies["HTTPEnable"] as? Int ?? 0) != 0
            state.httpsEnabled = (proxies["HTTPSEnable"] as? Int ?? 0) != 0
            state.socksEnabled = (proxies["SOCKSEnable"] as? Int ?? 0) != 0
            state.server = proxies["HTTPProxy"] as? String
                ?? proxies["HTTPSProxy"] as? String
                ?? proxies["SOCKSProxy"] as? String
            state.port = proxies["HTTPPort"] as? Int
                ?? proxies["HTTPSPort"] as? Int
                ?? proxies["SOCKSPort"] as? Int
        }

        // While the proxy is off the global dict omits the server entirely, but the
        // per-service setup dict keeps it — that is what the menu should display so
        // the user can see what will be switched on.
        if state.server == nil, let serviceID,
           let store = sharedStore(),
           let setup = SCDynamicStoreCopyValue(
               store, "Setup:/Network/Service/\(serviceID)/Proxies" as CFString) as? [String: Any] {
            state.server = setup["HTTPProxy"] as? String
                ?? setup["HTTPSProxy"] as? String
                ?? setup["SOCKSProxy"] as? String
            state.port = setup["HTTPPort"] as? Int
                ?? setup["HTTPSPort"] as? Int
                ?? setup["SOCKSPort"] as? Int
        }

        return state
    }

    private static func sharedStore() -> SCDynamicStore? {
        storeLock.lock()
        defer { storeLock.unlock() }
        if let cached = cachedStore { return cached }
        let created = SCDynamicStoreCreate(nil, "Lumen" as CFString, nil, nil)
        cachedStore = created
        return created
    }

    private static let storeLock = NSLock()
    private static var cachedStore: SCDynamicStore?

    /// UUID of the network service currently carrying traffic — the one the user
    /// expects a proxy switch to affect.
    private static func primaryServiceID() -> String? {
        guard let store = sharedStore(),
              let global = SCDynamicStoreCopyValue(
                  store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        else { return nil }
        return global["PrimaryService"] as? String
    }

    private static func serviceName(for serviceID: String) -> String? {
        guard let store = sharedStore(),
              let service = SCDynamicStoreCopyValue(
                  store, "Setup:/Network/Service/\(serviceID)" as CFString) as? [String: Any]
        else { return nil }
        return service["UserDefinedName"] as? String
    }

    /// Refreshes the cached state from the live configuration.
    @discardableResult
    func refresh() -> ProxyState {
        state = ProxyController.readState()
        return state
    }

    // MARK: - Writing

    /// Enables or disables HTTP, HTTPS and SOCKS together, then reports the result
    /// on the main queue.
    ///
    /// All three are switched as a set: leaving one behind produces confusing
    /// half-proxied traffic, and the usual local proxy ports carry both HTTP and
    /// SOCKS anyway.
    func setEnabled(_ enabled: Bool, completion: @escaping (Bool) -> Void) {
        let service = state.serviceName
        guard !service.isEmpty else {
            DispatchQueue.main.async { completion(false) }
            return
        }

        queue.async {
            let on = enabled ? "on" : "off"
            let commands = [
                ["-setwebproxystate", service, on],
                ["-setsecurewebproxystate", service, on],
                ["-setsocksfirewallproxystate", service, on]
            ]

            var allSucceeded = true
            for arguments in commands {
                if !ProxyController.runNetworksetup(arguments) { allSucceeded = false }
            }

            // SystemConfiguration can hand back the pre-write value for a moment
            // after networksetup exits, so poll until all three switches agree
            // instead of reporting a stale reading as a failure.
            let updated = ProxyController.waitForEnabled(enabled, timeout: 2.0)
            DispatchQueue.main.async {
                self.state = updated
                completion(updated.allProtocolsMatch(enabled) && allSucceeded)
            }
        }
    }

    /// Flips the current state.
    func toggle(completion: @escaping (Bool, ProxyState) -> Void) {
        let target = !state.isEnabled
        setEnabled(target) { success in
            completion(success, self.state)
        }
    }

    /// Polls until every protocol matches `enabled`, or the timeout elapses.
    ///
    /// Exits as soon as the system agrees, which is the normal case (~100–200 ms);
    /// the timeout only bounds the pathological case.
    private static func waitForEnabled(_ enabled: Bool, timeout: TimeInterval) -> ProxyState {
        let deadline = Date().addingTimeInterval(timeout)
        var latest = readState()
        while !latest.allProtocolsMatch(enabled) && Date() < deadline {
            usleep(20_000)
            latest = readState()
        }
        return latest
    }

    private static func runNetworksetup(_ arguments: [String]) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: networksetup)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
            // Drain before waiting so a chatty child cannot block on a full pipe.
            _ = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            NSLog("Lumen: networksetup failed to launch: %@", error.localizedDescription)
            return false
        }
    }
}
