import AppKit

/// A small translucent overlay that briefly shows the current level after a hotkey press.
final class HUDWindow: NSPanel {

    enum Kind {
        case brightness
        case volume
        case monitorVolume
        case mute(Bool)
        case proxy(Bool)

        var symbolName: String {
            switch self {
            case .brightness: return "sun.max.fill"
            case .volume, .monitorVolume: return "speaker.wave.2.fill"
            case .mute(let muted): return muted ? "speaker.slash.fill" : "speaker.wave.2.fill"
            case .proxy(let on): return on ? "network.badge.shield.half.filled" : "network.slash"
            }
        }

        var title: String {
            switch self {
            case .brightness: return "亮度"
            case .volume: return "音量"
            case .monitorVolume: return "显示器音量"
            case .mute(let muted): return muted ? "已静音" : "取消静音"
            case .proxy(let on): return on ? "代理已开启" : "代理已关闭"
            }
        }
    }

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let percentLabel = NSTextField(labelWithString: "")
    private let barBackground = NSView()
    private let barFill = NSView()
    private var barFillWidth = NSLayoutConstraint()

    private var hideWorkItem: DispatchWorkItem?

    private let panelSize = NSSize(width: 220, height: 96)
    /// Status-only HUDs hide the bar, so the panel shrinks to just the icon row
    /// instead of leaving an empty strip below the text.
    private let statusPanelSize = NSSize(width: 220, height: 52)
    private let barHeight: CGFloat = 6

    init() {
        super.init(contentRect: NSRect(origin: .zero, size: panelSize),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        configure()
    }

    private func configure() {
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        animationBehavior = .none

        let container = NSView(frame: NSRect(origin: .zero, size: panelSize))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        container.layer?.cornerRadius = 16
        container.layer?.borderWidth = 0.5
        container.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        container.layer?.masksToBounds = true

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentTintColor = .white
        iconView.imageScaling = .scaleProportionallyUpOrDown

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = NSColor.white.withAlphaComponent(0.65)
        titleLabel.stringValue = "亮度"

        percentLabel.translatesAutoresizingMaskIntoConstraints = false
        percentLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        percentLabel.textColor = .white
        percentLabel.alignment = .right
        percentLabel.stringValue = "0%"

        barBackground.translatesAutoresizingMaskIntoConstraints = false
        barBackground.wantsLayer = true
        barBackground.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
        barBackground.layer?.cornerRadius = barHeight / 2

        barFill.translatesAutoresizingMaskIntoConstraints = false
        barFill.wantsLayer = true
        barFill.layer?.backgroundColor = NSColor.white.cgColor
        barFill.layer?.cornerRadius = barHeight / 2

        container.addSubview(iconView)
        container.addSubview(titleLabel)
        container.addSubview(percentLabel)
        container.addSubview(barBackground)
        barBackground.addSubview(barFill)

        barFillWidth = barFill.widthAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            iconView.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),

            percentLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            percentLabel.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            percentLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),

            barBackground.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            barBackground.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            barBackground.heightAnchor.constraint(equalToConstant: barHeight),
            barBackground.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20),

            barFill.leadingAnchor.constraint(equalTo: barBackground.leadingAnchor),
            barFill.topAnchor.constraint(equalTo: barBackground.topAnchor),
            barFill.bottomAnchor.constraint(equalTo: barBackground.bottomAnchor),
            barFillWidth
        ])

        contentView = container
    }

    private func applyPanelHeight(_ height: CGFloat) {
        guard abs(frame.height - height) > 0.5 else { return }
        var newFrame = frame
        // Keep the top edge anchored so the HUD does not jump as it resizes.
        newFrame.origin.y += newFrame.height - height
        newFrame.size.height = height
        setFrame(newFrame, display: false)
        contentView?.frame = NSRect(x: 0, y: 0, width: panelSize.width, height: height)
    }

    /// Shows the HUD for a state that has no numeric level — the bar is hidden and
    /// the right-hand label carries the value instead.
    func showStatus(kind: Kind, detail: String, duration: TimeInterval = 0.9) {
        hideWorkItem?.cancel()

        titleLabel.stringValue = kind.title
        percentLabel.stringValue = detail

        if let image = NSImage(systemSymbolName: kind.symbolName, accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
            iconView.image = image.withSymbolConfiguration(config)
        }

        barBackground.isHidden = true
        applyPanelHeight(statusPanelSize.height)
        positionOnActiveScreen()

        if !isVisible {
            alphaValue = 0
            orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                animator().alphaValue = 1
            }
        } else {
            alphaValue = 1
            orderFrontRegardless()
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.22
                self.animator().alphaValue = 0
            }, completionHandler: {
                self.orderOut(nil)
            })
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    /// Shows the HUD with the given level (0...1) and auto-hides it.
    func show(kind: Kind, level: Double, duration: TimeInterval = 0.9) {
        hideWorkItem?.cancel()

        barBackground.isHidden = false
        applyPanelHeight(panelSize.height)
        let clamped = min(1.0, max(0.0, level))
        titleLabel.stringValue = kind.title
        percentLabel.stringValue = "\(Int((clamped * 100).rounded()))%"

        if let image = NSImage(systemSymbolName: kind.symbolName, accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
            iconView.image = image.withSymbolConfiguration(config)
        }

        let available = panelSize.width - 32
        let target = max(0, available * CGFloat(clamped))

        if isVisible {
            // Animate the fill for a responsive feel during rapid key repeats.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.08
                context.allowsImplicitAnimation = true
                barFillWidth.animator().constant = target
                contentView?.layoutSubtreeIfNeeded()
            }
        } else {
            barFillWidth.constant = target
            contentView?.layoutSubtreeIfNeeded()
        }

        positionOnActiveScreen()

        if !isVisible {
            alphaValue = 0
            orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                animator().alphaValue = 1
            }
        } else {
            alphaValue = 1
            orderFrontRegardless()
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.22
                self.animator().alphaValue = 0
            }, completionHandler: {
                self.orderOut(nil)
            })
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private func positionOnActiveScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }
        let origin = NSPoint(
            x: visible.midX - panelSize.width / 2,
            y: visible.minY + 96)
        setFrameOrigin(origin)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
