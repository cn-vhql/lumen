import AppKit
import ServiceManagement

/// Owns the status bar item, the menu, and routes hotkey actions to the controllers.
final class MenuBarController: NSObject, NSMenuDelegate {

    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let hud = HUDWindow()
    private let hotkeys = HotkeyManager()

    private var configuration: Configuration
    private let brightnessSlider = NSSlider()
    private let systemVolumeSlider = NSSlider()
    private let monitorVolumeSlider = NSSlider()
    private var hotkeyItem: NSMenuItem?
    private var launchAtLoginItem: NSMenuItem?
    private var muteItem: NSMenuItem?
    private var proxyItem: NSMenuItem?
    private var proxyEndpointItem: NSMenuItem?
    private var registrationWarning: [HotkeyAction] = []

    // Lazy so that hotkey registration completes before the (slower) DDC handshake.
    private lazy var ddc = DDCController.shared
    private lazy var audio = AudioController.shared
    private lazy var proxy = ProxyController.shared

    override init() {
        configuration = Configuration.load()
        // Materialise the config file on first launch so it is easy to find and edit.
        if !FileManager.default.fileExists(atPath: Configuration.fileURL.path) {
            configuration.save()
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        // Register hotkeys first: on a freshly installed bundle macOS may spend a
        // second or two verifying the signature, and DDC enumeration is not needed
        // before the hotkeys become live.
        installHotkeys()
        configureStatusItem()
        buildMenu()
        if #available(macOS 13.0, *) {
            debugLog("SMAppService status=\(SMAppService.mainApp.status.rawValue)")
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenConfigurationChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil)
    }

    // MARK: - Status item

    private func configureStatusItem() {
        if let button = statusItem.button {
            button.image = Self.menuBarIcon()
            button.toolTip = "Lumen — 亮度与音量"
        }
        statusItem.menu = menu
    }

    /// The menu bar glyph, loaded from the bundle so it matches the app icon.
    /// It is a template image: macOS tints it for the light or dark menu bar, so
    /// it stays legible in both. Falls back to a system symbol if the resource is
    /// missing, which keeps a broken bundle usable rather than iconless.
    private static func menuBarIcon() -> NSImage? {
        // 18 pt matches the visual weight of neighbouring menu bar extras; the
        // 128 px master is downsampled by AppKit with high-quality interpolation.
        let pointSize = NSSize(width: 18, height: 18)
        if let url = Bundle.main.url(forResource: "menubar", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.size = pointSize
            image.isTemplate = true
            return image
        }
        let fallback = NSImage(systemSymbolName: "sun.max.fill", accessibilityDescription: "Lumen")
        return fallback?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
    }

    // MARK: - Menu construction

    private func buildMenu() {
        menu.delegate = self
        menu.autoenablesItems = false
        rebuildMenuItems()
    }

    private func rebuildMenuItems() {
        menu.removeAllItems()

        let header = NSMenuItem(title: headerTitle(), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if !ddc.isAvailable {
            let warning = NSMenuItem(title: "未检测到可 DDC 控制的显示器", action: nil, keyEquivalent: "")
            warning.isEnabled = false
            menu.addItem(warning)
        }

        menu.addItem(.separator())

        // Brightness
        let brightnessLabel = NSMenuItem(title: "亮度", action: nil, keyEquivalent: "")
        brightnessLabel.isEnabled = false
        menu.addItem(brightnessLabel)

        let brightnessContainer = NSMenuItem()
        brightnessSlider.minValue = 0
        brightnessSlider.maxValue = 1
        brightnessSlider.doubleValue = ddc.brightness
        brightnessSlider.isContinuous = true
        brightnessSlider.target = self
        brightnessSlider.action = #selector(brightnessSliderChanged(_:))
        brightnessSlider.isEnabled = ddc.isAvailable
        brightnessSlider.frame = NSRect(x: 0, y: 0, width: 200, height: 24)
        let brightnessWrapper = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 28))
        brightnessSlider.frame = NSRect(x: 10, y: 2, width: 200, height: 24)
        brightnessWrapper.addSubview(brightnessSlider)
        brightnessContainer.view = brightnessWrapper
        menu.addItem(brightnessContainer)

        menu.addItem(.separator())

        // System volume
        let volumeLabel = NSMenuItem(title: "系统音量 · \(audio.outputDeviceName)",
                                     action: nil, keyEquivalent: "")
        volumeLabel.isEnabled = false
        menu.addItem(volumeLabel)

        let volumeContainer = NSMenuItem()
        systemVolumeSlider.minValue = 0
        systemVolumeSlider.maxValue = 1
        systemVolumeSlider.doubleValue = audio.volume ?? 0
        systemVolumeSlider.isContinuous = true
        systemVolumeSlider.target = self
        systemVolumeSlider.action = #selector(systemVolumeSliderChanged(_:))
        let volumeWrapper = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 28))
        systemVolumeSlider.frame = NSRect(x: 10, y: 2, width: 200, height: 24)
        volumeWrapper.addSubview(systemVolumeSlider)
        volumeContainer.view = volumeWrapper
        menu.addItem(volumeContainer)

        let muteItem = NSMenuItem(title: audio.isMuted ? "取消静音" : "静音",
                                  action: #selector(toggleMuteFromMenu),
                                  keyEquivalent: "")
        muteItem.target = self
        self.muteItem = muteItem
        menu.addItem(muteItem)

        // Monitor volume
        let monitorLabel = NSMenuItem(title: "显示器音量 · \(ddc.displayName.isEmpty ? "外接屏" : ddc.displayName)",
                                      action: nil, keyEquivalent: "")
        monitorLabel.isEnabled = false
        menu.addItem(monitorLabel)

        let monitorContainer = NSMenuItem()
        monitorVolumeSlider.minValue = 0
        monitorVolumeSlider.maxValue = 1
        monitorVolumeSlider.doubleValue = ddc.monitorVolume
        monitorVolumeSlider.isContinuous = true
        monitorVolumeSlider.target = self
        monitorVolumeSlider.action = #selector(monitorVolumeSliderChanged(_:))
        monitorVolumeSlider.isEnabled = ddc.isAvailable
        let monitorWrapper = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 28))
        monitorVolumeSlider.frame = NSRect(x: 10, y: 2, width: 200, height: 24)
        monitorWrapper.addSubview(monitorVolumeSlider)
        monitorContainer.view = monitorWrapper
        menu.addItem(monitorContainer)

        menu.addItem(.separator())

        // Volume target switch
        let targetItem = NSMenuItem(title: "音量热键控制", action: nil, keyEquivalent: "")
        let targetSubmenu = NSMenu()
        for target in Configuration.VolumeTarget.allCases {
            let item = NSMenuItem(title: target.title, action: #selector(selectVolumeTarget(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = target.rawValue
            item.state = configuration.volumeTarget == target ? .on : .off
            targetSubmenu.addItem(item)
        }
        targetItem.submenu = targetSubmenu
        menu.addItem(targetItem)

        // Hotkey summary
        let hotkeySummary = NSMenuItem(title: "快捷键", action: nil, keyEquivalent: "")
        let hotkeySubmenu = NSMenu()
        for action in HotkeyAction.allCases {
            guard let binding = configuration.binding(for: action) else { continue }
            let failed = registrationWarning.contains(action)
            let title = "\(action.title)    \(binding.displayName)\(failed ? "  ⚠︎ 占用" : "")"
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            hotkeySubmenu.addItem(item)
        }
        hotkeySubmenu.addItem(.separator())
        let revealItem = NSMenuItem(title: "打开配置文件…", action: #selector(revealConfig), keyEquivalent: "")
        revealItem.target = self
        hotkeySubmenu.addItem(revealItem)
        let reloadItem = NSMenuItem(title: "重新载入配置", action: #selector(reloadConfig), keyEquivalent: "")
        reloadItem.target = self
        hotkeySubmenu.addItem(reloadItem)
        let resetItem = NSMenuItem(title: "恢复默认快捷键", action: #selector(resetConfig), keyEquivalent: "")
        resetItem.target = self
        hotkeySubmenu.addItem(resetItem)
        hotkeySummary.submenu = hotkeySubmenu
        menu.addItem(hotkeySummary)

        menu.addItem(.separator())

        // System proxy
        let proxyItem = NSMenuItem(title: proxyTitle(),
                                   action: #selector(toggleProxyFromMenu),
                                   keyEquivalent: "")
        proxyItem.target = self
        proxyItem.state = proxy.state.isEnabled ? .on : .off
        self.proxyItem = proxyItem
        menu.addItem(proxyItem)

        let endpoint = proxyEndpointTitle()
        let endpointItem = NSMenuItem(title: endpoint ?? "", action: nil, keyEquivalent: "")
        endpointItem.isEnabled = false
        endpointItem.isHidden = endpoint == nil
        proxyEndpointItem = endpointItem
        menu.addItem(endpointItem)

        menu.addItem(.separator())

        let launchItem = NSMenuItem(title: "开机自动启动", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchItem.target = self
        launchItem.state = isLaunchAtLoginEnabled ? .on : .off
        launchAtLoginItem = launchItem
        menu.addItem(launchItem)

        let refreshItem = NSMenuItem(title: "重新同步显示器状态", action: #selector(resync), keyEquivalent: "")
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出 Lumen", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func headerTitle() -> String {
        let name = ddc.displayName
        let display = name.isEmpty ? "外接显示器" : name
        if ddc.isAvailable {
            return "\(display) · DDC 已连接"
        }
        return "\(display)"
    }

    private func proxyTitle() -> String {
        proxy.state.isEnabled ? "系统代理 · 已开启" : "系统代理 · 已关闭"
    }

    /// Shows the proxy address and which protocols are active, or just the address
    /// it would use when the proxy is off.
    ///
    /// The network service name is deliberately omitted: the row already acts on the
    /// current service, and the full string was getting truncated in the menu.
    private func proxyEndpointTitle() -> String? {
        let state = proxy.state
        guard state.server != nil else { return nil }
        if state.isEnabled {
            return "\(state.endpoint) · \(state.protocolSummary)"
        }
        return state.endpoint
    }

    // MARK: - Menu actions

    @objc private func brightnessSliderChanged(_ sender: NSSlider) {
        ddc.setBrightness(sender.doubleValue)
        hud.show(kind: .brightness, level: ddc.brightness, duration: 0.5)
    }

    @objc private func systemVolumeSliderChanged(_ sender: NSSlider) {
        audio.setVolume(sender.doubleValue)
        hud.show(kind: .volume, level: sender.doubleValue, duration: 0.5)
    }

    @objc private func monitorVolumeSliderChanged(_ sender: NSSlider) {
        ddc.setMonitorVolume(sender.doubleValue)
        hud.show(kind: .monitorVolume, level: ddc.monitorVolume, duration: 0.5)
    }

    @objc private func toggleMuteFromMenu() {
        audio.toggleMute()
        hud.show(kind: .mute(audio.isMuted), level: audio.isMuted ? 0 : (audio.volume ?? 0), duration: 0.7)
        rebuildMenuItems()
    }

    /// Retitles the mute row in place. The mute state can change from the hotkey, the
    /// menu item, the keyboard's own mute key or System Settings, so the label must be
    /// re-read on every menu open instead of only when this app flips it.
    private func refreshMuteRow() {
        muteItem?.title = audio.isMuted ? "取消静音" : "静音"
    }

    @objc private func toggleProxyFromMenu() {
        // The switch itself takes ~200 ms of subprocess work, so keep the menu
        // responsive and update it once the change has actually landed.
        proxy.toggle { [weak self] success, state in
            guard let self else { return }
            if success {
                self.hud.showStatus(kind: .proxy(state.isEnabled), detail: state.endpoint)
            } else {
                NSLog("Lumen: proxy toggle failed")
            }
            self.rebuildMenuItems()
        }
    }

    @objc private func selectVolumeTarget(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let target = Configuration.VolumeTarget(rawValue: raw) else { return }
        configuration.volumeTarget = target
        configuration.save()
        rebuildMenuItems()
    }

    @objc private func revealConfig() {
        configuration.save()
        NSWorkspace.shared.activateFileViewerSelecting([Configuration.fileURL])
    }

    @objc private func reloadConfig() {
        configuration = Configuration.load()
        installHotkeys()
        rebuildMenuItems()
    }

    @objc private func resetConfig() {
        configuration = .default
        configuration.save()
        installHotkeys()
        ddc.syncFromHardware()
        rebuildMenuItems()
    }

    @objc private func resync() {
        ddc.syncFromHardware()
        rebuildMenuItems()
    }

    @objc private func toggleLaunchAtLogin() {
        setLaunchAtLogin(!isLaunchAtLoginEnabled)
        if let item = launchAtLoginItem {
            item.state = isLaunchAtLoginEnabled ? .on : .off
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func screenConfigurationChanged() {
        ddc.syncFromHardware()
    }

    // MARK: - Menu delegate

    func menuWillOpen(_ menu: NSMenu) {
        ddc.syncFromHardware()
        proxy.refresh()
        brightnessSlider.doubleValue = ddc.brightness
        monitorVolumeSlider.doubleValue = ddc.monitorVolume
        systemVolumeSlider.doubleValue = audio.volume ?? 0
        // The mute state and the proxy can both be changed outside this app (keyboard
        // mute key, System Settings), so refresh those rows in place rather than
        // rebuilding the whole menu while it is opening.
        refreshMuteRow()
        refreshProxyRows()
    }

    /// Updates the proxy menu rows to match the current state.
    private func refreshProxyRows() {
        proxyItem?.title = proxyTitle()
        proxyItem?.state = proxy.state.isEnabled ? .on : .off
        if let endpoint = proxyEndpointTitle() {
            proxyEndpointItem?.title = endpoint
            proxyEndpointItem?.isHidden = false
        } else {
            proxyEndpointItem?.isHidden = true
        }
    }

    // MARK: - Hotkeys

    private func installHotkeys() {
        hotkeys.installHandler { [weak self] action in
            self?.handle(action)
        }
        registrationWarning = hotkeys.apply(configuration)
        debugLog("installed failures=\(registrationWarning.map { $0.rawValue })")
        if !registrationWarning.isEmpty {
            NSLog("Lumen: could not register hotkeys for %@",
                  registrationWarning.map { $0.rawValue }.joined(separator: ", "))
        }
    }

    /// Appends to a debug log so hotkey delivery can be verified without a debugger.
    private func debugLog(_ message: String) {
        guard ProcessInfo.processInfo.environment["LUMEN_DEBUG"] != nil else { return }
        let url = Configuration.supportDirectory.appendingPathComponent("debug.log")
        let line = "\(Date().timeIntervalSince1970) \(message)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    private func handle(_ action: HotkeyAction) {
        debugLog("handle \(action.rawValue)")
        switch action {
        case .brightnessUp:
            ddc.stepBrightness(by: configuration.brightnessStep)
            hud.show(kind: .brightness, level: ddc.brightness)
        case .brightnessDown:
            ddc.stepBrightness(by: -configuration.brightnessStep)
            hud.show(kind: .brightness, level: ddc.brightness)
        case .volumeUp, .volumeDown:
            let delta = action == .volumeUp ? configuration.volumeStep : -configuration.volumeStep
            switch configuration.volumeTarget {
            case .system:
                audio.stepVolume(by: delta)
                hud.show(kind: .volume, level: audio.volume ?? 0)
            case .monitor:
                ddc.stepMonitorVolume(by: delta)
                hud.show(kind: .monitorVolume, level: ddc.monitorVolume)
            }
        case .monitorVolumeUp:
            ddc.stepMonitorVolume(by: configuration.volumeStep)
            hud.show(kind: .monitorVolume, level: ddc.monitorVolume)
        case .monitorVolumeDown:
            ddc.stepMonitorVolume(by: -configuration.volumeStep)
            hud.show(kind: .monitorVolume, level: ddc.monitorVolume)
        case .toggleMute:
            audio.toggleMute()
            let muted = audio.isMuted
            hud.show(kind: .mute(muted), level: muted ? 0 : (audio.volume ?? 0))
            // Keep the menu row in step with the hotkey, like the menu item does.
            refreshMuteRow()
        case .openPanel:
            statusItem.button?.performClick(nil)
        }
    }

    // MARK: - Launch at login

    private var isLaunchAtLoginEnabled: Bool {
        guard #available(macOS 13.0, *) else { return false }
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        guard #available(macOS 13.0, *) else { return }
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status != .enabled { try service.register() }
            } else {
                if service.status == .enabled { try service.unregister() }
            }
        } catch {
            NSLog("Lumen: launch-at-login change failed: %@", error.localizedDescription)
        }
    }
}
