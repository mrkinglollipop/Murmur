import UIKit

/// In-bounds key popup / diacritic strip. Clipped by the keyboard chrome;
/// never draw this above the extension’s top edge.
final class KeyPreviewView: UIView {
    private let face = UIView()
    private let glyphLabel = UILabel()
    private var stripLabels: [UILabel] = []
    private(set) var items: [String] = []
    private(set) var selectedIndex = 0

    var selectedGlyph: String? {
        items.indices.contains(selectedIndex) ? items[selectedIndex] : nil
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isHidden = true
        face.layer.cornerCurve = .continuous
        addSubview(face)
        glyphLabel.textAlignment = .center
        glyphLabel.adjustsFontSizeToFitWidth = true
        glyphLabel.minimumScaleFactor = 0.6
        addSubview(glyphLabel)
    }

    required init?(coder: NSCoder) { nil }

    func applyAppearance(dark: Bool) {
        backgroundColor = .clear
        face.backgroundColor = KeyboardChromeTokens.letterKeyFill(dark: dark)
        face.layer.cornerRadius = KeyboardChromeTokens.keyCornerRadius
        glyphLabel.textColor = KeyboardChromeTokens.glyphColor(dark: dark)
        glyphLabel.font = .systemFont(ofSize: 28, weight: .regular)
        for label in stripLabels {
            label.textColor = KeyboardChromeTokens.glyphColor(dark: dark)
        }
    }

    func showPopup(glyph: String, keyFrame: CGRect, chromeBounds: CGRect, dark: Bool) {
        clearStrip()
        items = [glyph]
        selectedIndex = 0
        glyphLabel.isHidden = false
        glyphLabel.text = glyph
        applyAppearance(dark: dark)
        let width = max(36, keyFrame.width * 1.15)
        let height = max(40, keyFrame.height * 1.1)
        var frame = CGRect(
            x: keyFrame.midX - width / 2,
            y: keyFrame.minY - height - 3,
            width: width,
            height: height
        )
        frame = clamp(frame, in: chromeBounds)
        self.frame = frame
        face.frame = bounds
        glyphLabel.frame = bounds
        layer.cornerRadius = KeyboardChromeTokens.keyCornerRadius
        isHidden = false
    }

    func showStrip(items: [String], keyFrame: CGRect, preferBelow: Bool, chromeBounds: CGRect, dark: Bool) {
        guard !items.isEmpty else {
            dismiss()
            return
        }
        self.items = items
        selectedIndex = 0
        glyphLabel.isHidden = true
        rebuildStrip(dark: dark)
        applyAppearance(dark: dark)
        let cell: CGFloat = 34
        let height: CGFloat = 44
        let width = cell * CGFloat(items.count) + 8
        let y: CGFloat
        if preferBelow {
            y = min(keyFrame.maxY + 3, chromeBounds.maxY - height)
        } else {
            y = max(chromeBounds.minY, keyFrame.minY - height - 3)
        }
        var frame = CGRect(
            x: keyFrame.midX - width / 2,
            y: y,
            width: width,
            height: height
        )
        frame = clamp(frame, in: chromeBounds)
        self.frame = frame
        layoutStrip()
        isHidden = false
    }

    func select(at pointInChrome: CGPoint) {
        guard !stripLabels.isEmpty else { return }
        let local = convert(pointInChrome, from: superview)
        var next = selectedIndex
        for (index, label) in stripLabels.enumerated() where label.frame.insetBy(dx: -4, dy: -8).contains(local) {
            next = index
        }
        guard next != selectedIndex else { return }
        selectedIndex = next
        paintSelection()
    }

    func dismiss() {
        isHidden = true
        items = []
        selectedIndex = 0
        glyphLabel.text = nil
        clearStrip()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if stripLabels.isEmpty {
            face.frame = bounds
            glyphLabel.frame = bounds
        } else {
            layoutStrip()
        }
    }

    private func rebuildStrip(dark: Bool) {
        clearStrip()
        stripLabels = items.map { text in
            let label = UILabel()
            label.text = text
            label.textAlignment = .center
            label.font = .systemFont(ofSize: 22, weight: .regular)
            label.textColor = KeyboardChromeTokens.glyphColor(dark: dark)
            label.layer.cornerRadius = 6
            label.layer.cornerCurve = .continuous
            label.clipsToBounds = true
            addSubview(label)
            return label
        }
        paintSelection()
    }

    private func layoutStrip() {
        face.frame = bounds
        let inset: CGFloat = 4
        let count = max(stripLabels.count, 1)
        let cell = (bounds.width - inset * 2) / CGFloat(count)
        for (index, label) in stripLabels.enumerated() {
            label.frame = CGRect(
                x: inset + CGFloat(index) * cell,
                y: 4,
                width: cell,
                height: bounds.height - 8
            )
        }
    }

    private func paintSelection() {
        for (index, label) in stripLabels.enumerated() {
            label.backgroundColor = index == selectedIndex
                ? KeyboardChromeTokens.pressedKeyFill(dark: true)
                : .clear
        }
    }

    private func clearStrip() {
        stripLabels.forEach { $0.removeFromSuperview() }
        stripLabels = []
    }

    private func clamp(_ frame: CGRect, in bounds: CGRect) -> CGRect {
        var next = frame
        if next.minX < bounds.minX { next.origin.x = bounds.minX }
        if next.maxX > bounds.maxX { next.origin.x = bounds.maxX - next.width }
        if next.minY < bounds.minY { next.origin.y = bounds.minY }
        if next.maxY > bounds.maxY { next.origin.y = bounds.maxY - next.height }
        return next
    }
}
