import Foundation
import IOKit
import AppKit

// MARK: - IOKit private IOAVService symbols

private typealias CreateWithServiceFn = @convention(c) (CFAllocator?, io_service_t) -> UnsafeMutableRawPointer?
private typealias WriteI2CFn = @convention(c) (UnsafeMutableRawPointer?, UInt32, UInt32, UnsafeMutablePointer<UInt8>?, UInt32) -> Int32
private typealias ReadI2CFn = @convention(c) (UnsafeMutableRawPointer?, UInt32, UInt32, UnsafeMutablePointer<UInt8>?, UInt32) -> Int32

/// Controls an external display over DDC/CI.
///
/// Verified on macOS 27 / Apple Silicon against a DisplayPort monitor:
/// `DisplayServices` is unavailable on Mac mini (no internal panel), so DDC over
/// `IOAVService` is the only viable brightness path. A single VCP write costs ~2.7ms.
final class DDCController {

    static let shared = DDCController()

    enum VCP {
        static let brightness: UInt8 = 0x10
        static let contrast: UInt8 = 0x12
        static let volume: UInt8 = 0x62
    }

    private let queue = DispatchQueue(label: "local.lumen.ddc")
    /// Guards the published snapshot below. Writes happen on `queue`, reads come from
    /// the main thread (menu labels, sliders), so the fields need their own lock.
    private let stateLock = NSLock()
    private var _isAvailable = false
    private var _displayName = ""
    private var _brightnessMax: UInt16 = 100
    private var _volumeMax: UInt16 = 100
    private var _brightness: Double = 0.8
    private var _monitorVolume: Double = 0.5

    /// Timestamp of the last successful write. Used to decide whether the cached
    /// value is still trustworthy (the user may have moved the display's own buttons).
    private var lastWriteAt: Date = .distantPast
    private var av: UnsafeMutableRawPointer?
    private var writeFn: WriteI2CFn?
    private var readFn: ReadI2CFn?
    /// Pending read-back check. Only one is in flight at a time; a newer write cancels
    /// the previous one, which is what makes slider drags cheap.
    private var verifyWork: DispatchWorkItem?

    private let chipAddress: UInt32 = 0x37
    private let dataAddress: UInt32 = 0x51
    private let sourceAddress: UInt8 = 0x6E

    /// Raw max values as reported by the monitor (usually 100).
    var brightnessMax: UInt16 { stateLock.withLock { _brightnessMax } }
    var volumeMax: UInt16 { stateLock.withLock { _volumeMax } }

    /// Cached 0...1 values. The monitor's own readback lags behind writes by tens of
    /// milliseconds, so we keep our own authoritative value and only re-sync on demand.
    var brightness: Double { stateLock.withLock { _brightness } }
    var monitorVolume: Double { stateLock.withLock { _monitorVolume } }

    var isAvailable: Bool { stateLock.withLock { _isAvailable } }
    var displayName: String { stateLock.withLock { _displayName } }

    private init() {
        queue.sync {
            reconnectIfNeeded()
            guard isAvailable else { return }
            syncLocked()
        }
    }

    /// Updates the published snapshot under the lock. All internal writes go through
    /// here so main-thread readers never observe a torn value.
    private func publish(_ body: () -> Void) {
        stateLock.lock()
        body()
        stateLock.unlock()
    }

    /// Retries the connection when a previous attempt found no usable display.
    ///
    /// `init` can run before the monitor is ready — at login, right after wake, or
    /// while the display is being replugged — and the original code then left
    /// `isAvailable` false for the whole process lifetime, which killed every
    /// brightness action until Lumen was restarted. Reconnecting on demand makes
    /// the failure recoverable.
    ///
    /// Caller must already be on `queue`.
    private func reconnectIfNeeded() {
        guard !isAvailable else { return }
        forceReopen()
    }

    /// Throws the cached handle away and builds a new one.
    ///
    /// A handle is only valid for as long as the DP link that backs it. Display sleep,
    /// wake and link retraining all invalidate it, and the old handle then keeps
    /// accepting writes that the monitor silently drops — which is why the cached
    /// connection has to be rebuilt proactively instead of trusted once opened.
    ///
    /// Caller must already be on `queue`.
    private func forceReopen() {
        verifyWork?.cancel()
        releaseConnection()
        publish { _isAvailable = false }
        guard open() else {
            Log.debug("ddc: reopen found no DDC display")
            return
        }
        publish {
            _isAvailable = true
            _displayName = DDCController.resolveDisplayName()
        }
        Log.debug("ddc: reopened \(displayName)")
    }

    /// Drops the cached connection and re-opens it, then re-reads the monitor.
    ///
    /// Called when the system reports a screen reconfiguration or a wake: those are
    /// exactly the moments where the previous handle stops working, and without this
    /// the app would keep writing to a dead service until it was restarted.
    func invalidate(reason: String) {
        queue.sync {
            Log.debug("ddc: invalidate (\(reason))")
            forceReopen()
            guard isAvailable else { return }
            syncLocked()
        }
    }

    /// Drops the current IOAVService handle. `IOAVServiceCreate*` follows the CF
    /// "Create" ownership rule, so the handle has to be released or every reconnect
    /// would leak one.
    ///
    /// Caller must already be on `queue`.
    private func releaseConnection() {
        DDCController.release(av)
        av = nil
    }

    /// Releases an `IOAVService` obtained from the create-rule symbol above.
    /// `CFRelease` is not callable on a raw pointer, so the CoreFoundation
    /// ownership is expressed through `Unmanaged` instead.
    private static func release(_ handle: UnsafeMutableRawPointer?) {
        guard let handle else { return }
        Unmanaged<AnyObject>.fromOpaque(handle).release()
    }

    // MARK: - Connection

    /// Locates a display that answers DDC and keeps its `IOAVService` handle.
    ///
    /// Caller must already be on `queue`.
    @discardableResult
    private func open() -> Bool {
        guard let iokitBundle = CFBundleCreate(kCFAllocatorDefault,
                                               URL(fileURLWithPath: "/System/Library/Frameworks/IOKit.framework") as CFURL),
              let createPtr = CFBundleGetFunctionPointerForName(iokitBundle, "IOAVServiceCreateWithService" as CFString),
              let writePtr = CFBundleGetFunctionPointerForName(iokitBundle, "IOAVServiceWriteI2C" as CFString),
              let readPtr = CFBundleGetFunctionPointerForName(iokitBundle, "IOAVServiceReadI2C" as CFString)
        else {
            Log.debug("ddc: IOAVService symbols unavailable")
            return false
        }

        let create = unsafeBitCast(createPtr, to: CreateWithServiceFn.self)
        writeFn = unsafeBitCast(writePtr, to: WriteI2CFn.self)
        readFn = unsafeBitCast(readPtr, to: ReadI2CFn.self)

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("DCPAVServiceProxy"),
                                           &iterator) == KERN_SUCCESS else {
            Log.debug("ddc: DCPAVServiceProxy lookup failed")
            return false
        }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            guard let handle = create(kCFAllocatorDefault, service) else { continue }
            // Probe: only accept a service that actually answers a DDC read.
            av = handle
            if let probe = readVCPRaw(VCP.brightness), probe.max > 0 {
                publish { _brightnessMax = probe.max }
                if let v = readVCPRaw(VCP.volume), v.max > 0 {
                    publish { _volumeMax = v.max }
                }
                Log.debug("ddc: open ok brightnessMax=\(probe.max)")
                return true
            }
            Log.debug("ddc: candidate display did not answer VCP 0x10")
            // Rejected candidate: release it, otherwise probing a multi-display
            // setup would leak one IOAVService per display on every reconnect.
            av = nil
            DDCController.release(handle)
        }
        return false
    }

    // MARK: - Raw I2C

    private func writeVCPRaw(_ code: UInt8, _ value: UInt16) -> Bool {
        guard let av, let writeFn else { return false }
        var packet: [UInt8] = [0x84, 0x03, code,
                               UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF), 0]
        var checksum = sourceAddress
        for i in 0..<5 { checksum ^= packet[i] }
        packet[5] = checksum
        let length = UInt32(packet.count)
        let result = packet.withUnsafeMutableBufferPointer { buffer in
            writeFn(av, chipAddress, dataAddress, buffer.baseAddress, length)
        }
        if result != 0 {
            Log.debug("ddc: writeVCP \(hex(code))=\(value) returned \(String(format: "0x%08x", result))")
        }
        return result == 0
    }

    private func readVCPRaw(_ code: UInt8) -> (max: UInt16, cur: UInt16)? {
        guard let av, let writeFn, let readFn else { return nil }
        var request: [UInt8] = [0x82, 0x01, code, 0]
        var checksum = sourceAddress
        for i in 0..<3 { checksum ^= request[i] }
        request[3] = checksum
        let requestLength = UInt32(request.count)

        let wrote = request.withUnsafeMutableBufferPointer { buffer in
            writeFn(av, chipAddress, dataAddress, buffer.baseAddress, requestLength)
        }
        guard wrote == 0 else {
            Log.debug("ddc: readVCP \(hex(code)) request write returned \(String(format: "0x%08x", wrote))")
            return nil
        }

        var reply = [UInt8](repeating: 0, count: 11)
        let replyLength: UInt32 = 11
        let read = reply.withUnsafeMutableBufferPointer { buffer in
            readFn(av, chipAddress, dataAddress, buffer.baseAddress, replyLength)
        }
        guard read == 0 else {
            Log.debug("ddc: readVCP \(hex(code)) read returned \(String(format: "0x%08x", read))")
            return nil
        }
        // Sanity: a valid DDC/CI reply starts with the monitor's source address.
        guard reply[0] == sourceAddress || reply[0] == 0x6E else {
            Log.debug("ddc: readVCP \(hex(code)) bad reply source 0x\(String(format: "%02x", reply[0]))")
            return nil
        }

        let maxValue = UInt16(reply[6]) << 8 | UInt16(reply[7])
        let current = UInt16(reply[8]) << 8 | UInt16(reply[9])
        guard maxValue > 0 else { return nil }
        return (maxValue, current)
    }

    // MARK: - Public API

    /// Pulls current values from the monitor. Safe to call from any thread.
    func syncFromHardware() {
        queue.sync { syncLocked() }
    }

    /// Caller must already be on `queue`.
    private func syncLocked() {
        reconnectIfNeeded()
        guard isAvailable else { return }
        for attempt in 0..<3 {
            if let probe = readVCPRaw(VCP.brightness), probe.max > 0 {
                let ratio = clamp(Double(probe.cur) / Double(probe.max))
                publish {
                    _brightnessMax = probe.max
                    _brightness = ratio
                }
                break
            }
            if attempt < 2 { usleep(40_000) }
        }
        for attempt in 0..<3 {
            if let probe = readVCPRaw(VCP.volume), probe.max > 0 {
                let ratio = clamp(Double(probe.cur) / Double(probe.max))
                publish {
                    _volumeMax = probe.max
                    _monitorVolume = ratio
                }
                break
            }
            if attempt < 2 { usleep(40_000) }
        }
    }

    @discardableResult
    func setBrightness(_ value: Double) -> Bool {
        queue.sync {
            reconnectIfNeeded()
            guard isAvailable else { return false }
            let normalized = clamp(value)
            let raw = UInt16((normalized * Double(brightnessMax)).rounded())
            guard writeWithRecovery(VCP.brightness, raw) else { return false }
            publish { _brightness = normalized }
            lastWriteAt = Date()
            scheduleVerification(VCP.brightness, raw)
            return true
        }
    }

    @discardableResult
    func setMonitorVolume(_ value: Double) -> Bool {
        queue.sync {
            reconnectIfNeeded()
            guard isAvailable else { return false }
            let normalized = clamp(value)
            let raw = UInt16((normalized * Double(volumeMax)).rounded())
            guard writeWithRecovery(VCP.volume, raw) else { return false }
            publish { _monitorVolume = normalized }
            lastWriteAt = Date()
            scheduleVerification(VCP.volume, raw)
            return true
        }
    }

    /// Writes a VCP value, rebuilding the connection once if the first attempts fail.
    ///
    /// `IOAVServiceWriteI2C` reports nothing more useful than an IOReturn code, and a
    /// handle whose link was torn down can still return success while the monitor drops
    /// the packet. Retrying on a fresh handle covers both cases; if that also fails the
    /// connection is marked dead so the next call tries `open()` again.
    ///
    /// Caller must already be on `queue`.
    private func writeWithRecovery(_ code: UInt8, _ value: UInt16) -> Bool {
        if writeOnce(code, value) { return true }
        Log.debug("ddc: write \(hex(code)) failed, reopening")
        forceReopen()
        guard isAvailable else { return false }
        if writeOnce(code, value) { return true }
        Log.debug("ddc: write \(hex(code)) failed twice, marking unavailable")
        verifyWork?.cancel()
        releaseConnection()
        publish { _isAvailable = false }
        return false
    }

    private func writeOnce(_ code: UInt8, _ value: UInt16) -> Bool {
        for attempt in 0..<3 {
            if writeVCPRaw(code, value) { return true }
            if attempt < 2 { usleep(30_000) }
        }
        return false
    }

    /// Reads the value back shortly after a write.
    ///
    /// A monitor that accepted the write reports the new value; one whose link is gone
    /// keeps reporting the old one, which is the only observable symptom of a stale
    /// handle. Runs off the write path so a slider drag does not pay for the round trip.
    ///
    /// Caller must already be on `queue`.
    private func scheduleVerification(_ code: UInt8, _ expected: UInt16) {
        verifyWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.verify(code, expected)
        }
        verifyWork = work
        queue.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// Caller must already be on `queue`.
    private func verify(_ code: UInt8, _ expected: UInt16) {
        guard isAvailable, let probe = readVCPRaw(code), probe.max > 0 else { return }
        // Monitors round and clamp; within 2% of full scale still counts as applied.
        let tolerance = max(2, Int(probe.max) / 50)
        guard abs(Int(probe.cur) - Int(expected)) > tolerance else { return }
        Log.debug("ddc: verify \(hex(code)) expected=\(expected) actual=\(probe.cur), reopening")
        forceReopen()
        guard isAvailable else { return }
        _ = writeOnce(code, expected)
    }

    private func hex(_ code: UInt8) -> String { String(format: "0x%02x", code) }

    /// Re-reads hardware if nothing was written recently, so hotkey steps start from
    /// the monitor's real value even after external changes (display buttons, another app).
    private func refreshIfStale() {
        guard Date().timeIntervalSince(lastWriteAt) > 1.5 else { return }
        if let probe = readVCPRaw(VCP.brightness), probe.max > 0 {
            let ratio = clamp(Double(probe.cur) / Double(probe.max))
            publish {
                _brightnessMax = probe.max
                _brightness = ratio
            }
        }
        if let probe = readVCPRaw(VCP.volume), probe.max > 0 {
            let ratio = clamp(Double(probe.cur) / Double(probe.max))
            publish {
                _volumeMax = probe.max
                _monitorVolume = ratio
            }
        }
        lastWriteAt = Date()
    }

    /// Returns false when the display could not be reached, so the caller can say so
    /// instead of showing a level that never reached the monitor.
    @discardableResult
    func stepBrightness(by delta: Double) -> Bool {
        queue.sync {
            reconnectIfNeeded()
            guard isAvailable else { return false }
            refreshIfStale()
            let normalized = clamp(brightness + delta)
            let raw = UInt16((normalized * Double(brightnessMax)).rounded())
            guard writeWithRecovery(VCP.brightness, raw) else { return false }
            publish { _brightness = normalized }
            lastWriteAt = Date()
            scheduleVerification(VCP.brightness, raw)
            return true
        }
    }

    @discardableResult
    func stepMonitorVolume(by delta: Double) -> Bool {
        queue.sync {
            reconnectIfNeeded()
            guard isAvailable else { return false }
            refreshIfStale()
            let normalized = clamp(monitorVolume + delta)
            let raw = UInt16((normalized * Double(volumeMax)).rounded())
            guard writeWithRecovery(VCP.volume, raw) else { return false }
            publish { _monitorVolume = normalized }
            lastWriteAt = Date()
            scheduleVerification(VCP.volume, raw)
            return true
        }
    }

    /// Human-readable name of the main display, used for menu labels.
    private static func resolveDisplayName() -> String {
        if let screen = NSScreen.main, !screen.localizedName.isEmpty {
            return screen.localizedName
        }
        return "外接显示器"
    }

    private func clamp(_ v: Double) -> Double {
        min(1.0, max(0.0, v))
    }
}
