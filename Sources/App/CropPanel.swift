import AppKit

/// Small window with a slider per edge for cutting the iPad status bar or an
/// app's toolbar off the picture. Changes show live. Only you see this window.
final class CropPanel: NSPanel {
    var onChange: ((CropInsets) -> Void)?
    private var insets: CropInsets
    private var sliders: [NSSlider] = []
    private var values: [NSTextField] = []
    private static let edges = ["Top", "Bottom", "Left", "Right"]

    init(insets: CropInsets) {
        self.insets = insets
        super.init(contentRect: NSRect(x: 0, y: 0, width: 340, height: 220),
                   styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        title = "Crop"
        sharingType = .none
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false

        let grid = NSGridView()
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        for (i, edge) in Self.edges.enumerated() {
            let slider = NSSlider(value: 0, minValue: 0, maxValue: 30, target: self, action: #selector(slid(_:)))
            slider.tag = i
            slider.isContinuous = true
            slider.widthAnchor.constraint(equalToConstant: 200).isActive = true
            let value = NSTextField(labelWithString: "0%")
            value.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            value.widthAnchor.constraint(equalToConstant: 44).isActive = true
            sliders.append(slider)
            values.append(value)
            grid.addRow(with: [NSTextField(labelWithString: edge), slider, value])
        }

        let note = NSTextField(wrappingLabelWithString: "Cuts the edges off what the student sees. Start with a preset, then nudge the sliders until the bar you want gone just disappears.")
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 310

        let none = NSButton(title: "No Crop", target: self, action: #selector(presetNone))
        let status = NSButton(title: "Status Bar", target: self, action: #selector(presetStatus))
        status.toolTip = "Hides the iPad's clock and battery bar"
        let toolbar = NSButton(title: "Status Bar + Toolbar", target: self, action: #selector(presetToolbar))
        toolbar.toolTip = "Hides the status bar and a note app's toolbar (about 10% of the top)"
        let presets = NSStackView(views: [none, status, toolbar])
        presets.spacing = 6

        let stack = NSStackView(views: [presets, grid, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        contentView = stack
        setContentSize(stack.fittingSize)
        show(insets)
    }

    private func show(_ c: CropInsets) {
        insets = c
        for (i, v) in [c.top, c.bottom, c.left, c.right].enumerated() {
            sliders[i].doubleValue = v * 100
            values[i].stringValue = String(format: "%.1f%%", v * 100)
        }
    }

    private func apply(_ c: CropInsets) {
        show(c.clamped)
        onChange?(insets)
    }

    @objc private func slid(_ sender: NSSlider) {
        var c = insets
        let v = sender.doubleValue / 100
        switch sender.tag {
        case 0: c.top = v
        case 1: c.bottom = v
        case 2: c.left = v
        default: c.right = v
        }
        apply(c)
    }

    @objc private func presetNone() { apply(.none) }
    @objc private func presetStatus() { apply(.statusBar) }
    @objc private func presetToolbar() { apply(CropInsets(top: 0.1)) }
}
