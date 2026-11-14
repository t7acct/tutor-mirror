import AppKit

/// The lag meter lives in its own little window glued to the mirror window.
/// When you share just the mirror window in Zoom/Teams, the student doesn't
/// see this panel — only you do.
final class LagMeterPanel: NSPanel {
    private let label = NSTextField(labelWithString: "")
    private var timer: Timer?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 300, height: 120),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        sharingType = .none
        collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]

        let box = NSVisualEffectView()
        box.material = .hudWindow
        box.state = .active
        box.blendingMode = .behindWindow
        box.wantsLayer = true
        box.layer?.cornerRadius = 8
        contentView = box

        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .white
        label.maximumNumberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: box.topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -8),
        ])
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func ms(_ v: Double) -> String { String(format: "%3.0f", v * 1000) }

    private func refresh() {
        let s = LatencyStats.shared.summary()
        var lines: [String] = []
        if s.width > 0 {
            lines.append("stream   \(s.width)×\(s.height)  \(s.receivedFPS) fps in · \(s.shownFPS) shown")
        } else {
            lines.append("stream   waiting for iPad…")
        }
        // Wi-Fi: measured round trip of the clock-sync pings (reliable).
        // The iPad's own frame timestamps aren't precise enough for a one-way
        // number, so the true end-to-end total needs the stopwatch photo test.
        if let rtt = ClockSync.shared.roundTrip {
            lines.append("wifi     \(ms(rtt)) ms round trip  (worst: \(ms(ClockSync.shared.worstRoundTrip ?? rtt)))")
        } else {
            lines.append("wifi       – ms  (measuring…)")
        }
        lines.append("decode   \(ms(s.decode.avg)) ms  (worst 5%: \(ms(s.decode.p95)))")
        lines.append("display  \(ms(s.display.avg)) ms  (worst 5%: \(ms(s.display.p95)))")
        lines.append("MAC SIDE \(ms(s.macSide.avg)) ms  (worst 5%: \(ms(s.macSide.p95)))")
        lines.append("hiccup   \(ms(s.worstGap)) ms longest gap · \(s.skipped) skipped")
        label.stringValue = lines.joined(separator: "\n")

        let size = label.fittingSize
        let newSize = NSSize(width: max(300, size.width + 20), height: size.height + 16)
        if abs(frame.width - newSize.width) > 1 || abs(frame.height - newSize.height) > 1 {
            setContentSize(newSize)
        }
        reposition()
    }

    /// Pin to the top-left corner of the parent window's content area.
    func reposition() {
        guard let parent = parent else { return }
        let content = parent.contentLayoutRect
        let topLeft = parent.convertPoint(toScreen: NSPoint(x: content.minX + 10, y: content.maxY - 10))
        setFrameTopLeftPoint(topLeft)
    }
}
