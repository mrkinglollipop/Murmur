import UIKit

/// Wispr-shaped QWERTY chrome. Murmur dictation replaces the keys while a take is active.
final class KeyboardChromeView: UIView {
    var onMic: (() -> Void)?
    var onCancel: (() -> Void)?
    var onDelete: (() -> Void)?
    var onGlobe: (() -> Void)?
    var onInsert: ((String) -> Void)?
    var onSpaceDrag: ((Int) -> Void)?
    var onCandidate: ((Int) -> Void)?

    private enum Page { case letters, numbers, symbols }

    private let glassBackdrop = UIVisualEffectView(effect: UIGlassContainerEffect())
    private let topBar = AccessoryBarView()
    private let grid = UIView()
    private let globeButton = UIButton(type: .system)

    private let listeningPanel = UIView()
    private let cancelButton = UIButton(type: .system)
    private let formatButton = UIButton(type: .system)
    private let finishButton = UIButton(type: .system)
    private let waveformView = MeterWaveformView()
    private let listeningStatusLabel = UILabel()
    private let microphoneLabel = UILabel()

    private let errorBanner = UIView()
    private let errorLabel = UILabel()
    private let errorDismissButton = UIButton(type: .system)

    private var page: Page = .letters
    private enum ShiftState { case off, once, locked }
    private var shiftState: ShiftState = .once
    private var lastShiftTap: ContinuousClock.Instant?
    private var dark = true
    private var micEnabled = true
    private var micHidden = false
    private var sessionActive = false
    private var returnTitle = "return"
    private var showsGlobe = false
    private var keyViews: [KeyView] = []
    private var deleteRepeatTask: Task<Void, Never>?
    private let keyHaptic = UIImpactFeedbackGenerator(style: .light)
    private var spaceTrackpadUsed = false
    private var lastSpaceOffset = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureChrome()
        applyColors()
        rebuild()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        deleteRepeatTask?.cancel()
    }

    func setStatus(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if sessionActive || trimmed.isEmpty {
            topBar.setCaption("")
        } else {
            topBar.setCaption(text)
        }
        let lowered = text.lowercased()
        if lowered.contains("transcribing") {
            listeningStatusLabel.text = "Transcribing…"
            microphoneLabel.text = "Please wait"
            setListeningActionsEnabled(false)
        } else if lowered.contains("starting") || lowered.contains("murmur is on") {
            listeningStatusLabel.text = lowered.contains("murmur is on") ? "Murmur is on" : "Starting…"
            microphoneLabel.text = lowered.contains("murmur is on")
                ? "Swipe back to your app"
                : "Opening Murmur"
            cancelButton.isEnabled = true
            finishButton.isEnabled = false
        } else if lowered.contains("paused") {
            listeningStatusLabel.text = "Paused"
            microphoneLabel.text = "iPhone Microphone"
            setListeningActionsEnabled(true)
        } else {
            listeningStatusLabel.text = "Listening"
            microphoneLabel.text = "iPhone Microphone"
            setListeningActionsEnabled(true)
        }
    }

    func setRecording(_ on: Bool) {
        sessionActive = on
        updateVisibility()
    }

    func setMeterLevel(_ level: Double) {
        waveformView.level = CGFloat(level)
    }

    func setAutomaticCapitalization(_ enabled: Bool, allCharacters: Bool) {
        if shiftState == .locked, !allCharacters { return }
        let next: ShiftState
        if allCharacters {
            next = .locked
        } else {
            next = enabled ? .once : .off
        }
        guard shiftState != next else { return }
        shiftState = next
        rebuild()
    }

    func setShowsGlobe(_ show: Bool) {
        showsGlobe = show
        globeButton.isHidden = !show
        setNeedsLayout()
    }

    func setCandidates(_ words: [String]) {
        topBar.setCandidates(words)
    }

    func setFullAccess(_ ok: Bool) {
        micEnabled = ok
        topBar.setMicEnabled(ok)
        topBar.setGifEnabled(false)
    }

    func setSecure(_ secure: Bool) {
        micHidden = secure
        if secure { setStatus("Dictation off in secure fields") }
        updateVisibility()
    }

    func setAppearance(dark: Bool) {
        guard self.dark != dark else { return }
        self.dark = dark
        applyColors()
        rebuild()
    }

    func setReturnTitle(_ title: String) {
        let next = title.isEmpty ? "return" : title
        guard returnTitle != next else { return }
        returnTitle = next
        rebuild()
    }

    /// Wispr-style dismissible capture-failure card over the keyboard.
    func showError(_ message: String) {
        errorLabel.text = message
        errorBanner.isHidden = false
        bringSubviewToFront(errorBanner)
        setNeedsLayout()
    }

    func dismissError() {
        errorBanner.isHidden = true
        errorLabel.text = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side: CGFloat = 8
        let topHeight: CGFloat = 48
        let globeHeight: CGFloat = showsGlobe ? 28 : 0

        topBar.frame = CGRect(x: side, y: 3, width: bounds.width - side * 2, height: topHeight)
        glassBackdrop.frame = bounds

        globeButton.frame = CGRect(x: side + 2, y: bounds.height - globeHeight, width: 42, height: globeHeight)
        grid.frame = CGRect(
            x: side,
            y: topBar.frame.maxY,
            width: bounds.width - side * 2,
            height: max(0, (showsGlobe ? globeButton.frame.minY : bounds.height - 3) - topBar.frame.maxY)
        )
        listeningPanel.frame = bounds
        cancelButton.frame = CGRect(x: 10, y: 12, width: 44, height: 44)
        formatButton.frame = CGRect(x: bounds.midX - 44, y: 17, width: 88, height: 32)
        finishButton.frame = CGRect(x: bounds.width - 54, y: 12, width: 44, height: 44)
        waveformView.frame = CGRect(x: bounds.midX - 58, y: bounds.midY - 38, width: 116, height: 48)
        listeningStatusLabel.frame = CGRect(x: 44, y: waveformView.frame.maxY + 9, width: bounds.width - 88, height: 23)
        microphoneLabel.frame = CGRect(x: 44, y: listeningStatusLabel.frame.maxY - 2, width: bounds.width - 88, height: 20)

        if !errorBanner.isHidden {
            let maxWidth = min(bounds.width - 32, 340)
            let labelWidth = maxWidth - 24
            let labelHeight = errorLabel.sizeThatFits(
                CGSize(width: labelWidth, height: 200)
            ).height
            let bannerHeight = min(bounds.height - 24, max(96, labelHeight + 52))
            errorBanner.frame = CGRect(
                x: (bounds.width - maxWidth) / 2,
                y: max(12, (bounds.height - bannerHeight) / 2),
                width: maxWidth,
                height: bannerHeight
            )
            errorLabel.frame = CGRect(x: 12, y: 12, width: labelWidth, height: labelHeight)
            errorDismissButton.frame = CGRect(
                x: 12,
                y: bannerHeight - 40,
                width: maxWidth - 24,
                height: 32
            )
            bringSubviewToFront(errorBanner)
        }

        bringSubviewToFront(globeButton)
        layoutKeys()
    }

    private func configureChrome() {
        insertSubview(glassBackdrop, at: 0)
        glassBackdrop.isUserInteractionEnabled = false
        addSubview(topBar)
        topBar.onMic = { [weak self] in self?.onMic?() }
        topBar.onCandidate = { [weak self] index in self?.onCandidate?(index) }
        addSubview(grid)
        addSubview(globeButton)
        addSubview(listeningPanel)
        listeningPanel.addSubview(cancelButton)
        listeningPanel.addSubview(formatButton)
        listeningPanel.addSubview(finishButton)
        listeningPanel.addSubview(waveformView)
        listeningPanel.addSubview(listeningStatusLabel)
        listeningPanel.addSubview(microphoneLabel)

        addSubview(errorBanner)
        errorBanner.addSubview(errorLabel)
        errorBanner.addSubview(errorDismissButton)
        errorBanner.isHidden = true
        errorBanner.layer.cornerRadius = 14
        errorBanner.layer.cornerCurve = .continuous
        errorBanner.clipsToBounds = true
        errorBanner.accessibilityIdentifier = "murmur.keyboard.error"

        errorLabel.font = .systemFont(ofSize: 15, weight: .regular)
        errorLabel.textAlignment = .center
        errorLabel.numberOfLines = 0
        errorLabel.accessibilityIdentifier = "murmur.keyboard.error.message"

        errorDismissButton.setTitle("Dismiss", for: .normal)
        errorDismissButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        errorDismissButton.addTarget(self, action: #selector(tapDismissError), for: .touchUpInside)
        errorDismissButton.accessibilityLabel = "Dismiss error"
        errorDismissButton.accessibilityIdentifier = "murmur.keyboard.error.dismiss"

        configureCircle(cancelButton, symbol: "xmark", action: #selector(tapCancel))
        cancelButton.accessibilityLabel = "Cancel dictation"
        cancelButton.accessibilityIdentifier = "murmur.keyboard.cancel"

        formatButton.setTitle("Format", for: .normal)
        formatButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        formatButton.isEnabled = false
        formatButton.accessibilityLabel = "Format unavailable"
        formatButton.accessibilityIdentifier = "murmur.keyboard.format"

        configureCircle(finishButton, symbol: "checkmark", action: #selector(tapMic))
        finishButton.accessibilityLabel = "Finish dictation"
        finishButton.accessibilityIdentifier = "murmur.keyboard.finish"

        waveformView.accessibilityElementsHidden = true

        listeningStatusLabel.font = .systemFont(ofSize: 14, weight: .medium)
        listeningStatusLabel.textAlignment = .center
        listeningStatusLabel.text = "Listening"
        listeningStatusLabel.accessibilityLabel = "Dictation status"
        listeningStatusLabel.accessibilityIdentifier = "murmur.keyboard.status"
        microphoneLabel.font = .systemFont(ofSize: 13, weight: .regular)
        microphoneLabel.textAlignment = .center
        microphoneLabel.text = "iPhone Microphone"
        microphoneLabel.accessibilityIdentifier = "murmur.keyboard.microphone"

        globeButton.setImage(UIImage(systemName: "globe"), for: .normal)
        globeButton.addTarget(self, action: #selector(tapGlobe), for: .touchUpInside)
        globeButton.accessibilityLabel = "Next keyboard"
        globeButton.accessibilityIdentifier = "murmur.keyboard.next"
        updateVisibility()
    }

    private func configureCircle(_ button: UIButton, symbol: String, action: Selector) {
        button.setImage(
            UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)),
            for: .normal
        )
        button.layer.cornerRadius = 22
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    private func setListeningActionsEnabled(_ enabled: Bool) {
        cancelButton.isEnabled = enabled
        finishButton.isEnabled = enabled
        cancelButton.alpha = enabled ? 1 : 0.4
        finishButton.alpha = enabled ? 1 : 0.4
    }

    private func updateVisibility() {
        let showPanel = sessionActive && !micHidden
        listeningPanel.isHidden = !showPanel
        topBar.isHidden = showPanel
        grid.isHidden = showPanel
        globeButton.isHidden = !showsGlobe
        topBar.setMicHidden(micHidden)
        setNeedsLayout()
    }

    private func applyColors() {
        backgroundColor = KeyboardChromeTokens.keyboardBackdrop(dark: dark)
        topBar.setAppearance(dark: dark)
        globeButton.tintColor = KeyboardChromeTokens.glyphColor(dark: dark)

        listeningPanel.backgroundColor = KeyboardChromeTokens.listeningFill(dark: dark)
        cancelButton.backgroundColor = dark ? UIColor(white: 0.22, alpha: 1) : .white
        cancelButton.tintColor = KeyboardChromeTokens.glyphColor(dark: dark)
        finishButton.backgroundColor = dark ? .white : .black
        finishButton.tintColor = dark ? .black : .white
        formatButton.setTitleColor(
            KeyboardChromeTokens.glyphColor(dark: dark).withAlphaComponent(0.22),
            for: .disabled
        )
        waveformView.tintColor = KeyboardChromeTokens.glyphColor(dark: dark)

        errorBanner.backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.96)
        errorLabel.textColor = .label
        errorDismissButton.setTitleColor(.systemBlue, for: .normal)
        listeningStatusLabel.textColor = KeyboardChromeTokens.glyphColor(dark: dark)
        microphoneLabel.textColor = KeyboardChromeTokens.glyphColor(dark: dark).withAlphaComponent(0.65)
    }

    private func rebuild() {
        deleteRepeatTask?.cancel()
        deleteRepeatTask = nil
        keyViews.forEach { $0.removeFromSuperview() }
        keyViews = specs().map { spec in
            let key = KeyView(spec: spec, dark: dark)
            if case .delete = spec.action {
                key.addTarget(self, action: #selector(beginDelete(_:)), for: .touchDown)
                key.addTarget(
                    self,
                    action: #selector(endDelete(_:)),
                    for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit]
                )
            } else {
                key.addTarget(self, action: #selector(hapticDown), for: .touchDown)
                key.addTarget(self, action: #selector(tapKey(_:)), for: .touchUpInside)
            }
            if spec.title == "Murmur" {
                let pan = UIPanGestureRecognizer(target: self, action: #selector(spacePan(_:)))
                pan.cancelsTouchesInView = false
                key.addGestureRecognizer(pan)
            }
            grid.addSubview(key)
            return key
        }
        applyColors()
        updateVisibility()
        layoutKeys()
    }

    private func layoutKeys() {
        let rows = Dictionary(grouping: keyViews) { $0.spec.row }
        let gap: CGFloat = KeyboardChromeTokens.keyGap
        let rowGap: CGFloat = KeyboardChromeTokens.rowGap
        let rowCount: CGFloat = 4
        let height = max(36, (grid.bounds.height - rowGap * (rowCount - 1)) / rowCount)
        for row in 0..<Int(rowCount) {
            guard let keys = rows[row] else { continue }
            let y = CGFloat(row) * (height + rowGap)
            let units = keys.reduce(0) { $0 + $1.spec.units }
            let unitWidth = max(8, (grid.bounds.width - gap * CGFloat(keys.count - 1)) / units)
            var x: CGFloat = 0
            for key in keys {
                let width = unitWidth * key.spec.units
                key.frame = CGRect(x: x, y: y, width: width, height: height)
                x += width + gap
            }
        }
    }

    private func specs() -> [KeySpec] {
        switch page {
        case .letters:
            return letterSpecs()
        case .numbers:
            return row(["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"], 0)
                + row(["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""], 1)
                + symbolsThird(shiftTitle: "#+=", values: [".", ",", "?", "!", "'"])
                + bottom(modeTitle: "ABC")
        case .symbols:
            return row(["[", "]", "{", "}", "#", "%", "^", "*", "+", "="], 0)
                + row(["_", "\\", "|", "~", "<", ">", "€", "£", "¥", "•"], 1)
                + symbolsThird(shiftTitle: "123", values: [".", ",", "?", "!", "'"])
                + bottom(modeTitle: "ABC")
        }
    }

    private func letterSpecs() -> [KeySpec] {
        let letters = [Array("qwertyuiop"), Array("asdfghjkl"), Array("zxcvbnm")]
        var result: [KeySpec] = []
        for (row, chars) in letters.enumerated() {
            if row == 1 { result.append(KeySpec(row: 1, units: 0.4, title: "", action: .spacer)) }
            if row == 2 {
                let symbol = shiftState == .locked ? "capslock.fill" : (shiftState == .off ? "shift" : "shift.fill")
                result.append(KeySpec(
                    row: 2,
                    units: 1.4,
                    title: shiftState == .locked ? "caps lock" : "shift",
                    action: .shift,
                    symbol: symbol,
                    isSelected: shiftState != .off
                ))
            }
            for ch in chars {
                let base = String(ch)
                let glyph = shiftState == .off ? base : base.uppercased()
                result.append(KeySpec(row: row, units: 1, title: glyph, action: .insert(glyph)))
            }
            if row == 1 { result.append(KeySpec(row: 1, units: 0.4, title: "", action: .spacer)) }
            if row == 2 { result.append(KeySpec(row: 2, units: 1.4, title: "delete", action: .delete, symbol: "delete.backward")) }
        }
        return result + bottom(modeTitle: "123")
    }

    private func row(_ values: [String], _ row: Int) -> [KeySpec] {
        values.map { KeySpec(row: row, units: 1, title: $0, action: .insert($0)) }
    }

    private func symbolsThird(shiftTitle: String, values: [String]) -> [KeySpec] {
        var result = [KeySpec(row: 2, units: 1.6, title: shiftTitle, action: .mode)]
        result += values.map { KeySpec(row: 2, units: 1, title: $0, action: .insert($0)) }
        result.append(KeySpec(row: 2, units: 1.6, title: "delete", action: .delete, symbol: "delete.backward"))
        return result
    }

    private func bottom(modeTitle: String) -> [KeySpec] {
        [
            KeySpec(row: 3, units: 1.35, title: modeTitle, action: .mode),
            KeySpec(row: 3, units: 4.15, title: "Murmur", action: .insert(" ")),
            KeySpec(row: 3, units: 1.65, title: returnTitle, action: .insert("\n"))
        ]
    }

    @objc private func hapticDown() {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        keyHaptic.impactOccurred(intensity: 0.55)
    }

    @objc private func spacePan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: self).x
        switch gesture.state {
        case .began:
            spaceTrackpadUsed = false
            lastSpaceOffset = 0
        case .changed:
            let offset = Int((translation / 8).rounded())
            if abs(translation) > 8 { spaceTrackpadUsed = true }
            let delta = offset - lastSpaceOffset
            if delta != 0 {
                lastSpaceOffset = offset
                onSpaceDrag?(delta)
            }
        default:
            break
        }
    }

    @objc private func tapMic() { onMic?() }
    @objc private func tapCancel() { onCancel?() }
    @objc private func tapDismissError() { dismissError() }
    @objc private func tapGlobe() { onGlobe?() }

    @objc private func beginDelete(_: KeyView) {
        hapticDown()
        onDelete?()
        deleteRepeatTask?.cancel()
        deleteRepeatTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(420))
            while !Task.isCancelled {
                await MainActor.run { self?.onDelete?() }
                try? await Task.sleep(for: .milliseconds(70))
            }
        }
    }

    @objc private func endDelete(_: KeyView) {
        deleteRepeatTask?.cancel()
        deleteRepeatTask = nil
    }

    @objc private func tapKey(_ sender: KeyView) {
        switch sender.spec.action {
        case .spacer:
            return
        case .insert(let text):
            if text == " ", spaceTrackpadUsed {
                spaceTrackpadUsed = false
                return
            }
            lastShiftTap = nil
            onInsert?(text)
            if page == .letters, text.count == 1, text != " ", text != "\n", shiftState == .once {
                shiftState = .off
                rebuild()
            }
        case .delete:
            lastShiftTap = nil
            onDelete?()
        case .shift:
            UIDevice.current.playInputClick()
            let now = ContinuousClock().now
            if let lastShiftTap, now - lastShiftTap < .milliseconds(350) {
                shiftState = .locked
                self.lastShiftTap = nil
            } else {
                shiftState = shiftState == .off ? .once : .off
                lastShiftTap = now
            }
            rebuild()
        case .mode:
            UIDevice.current.playInputClick()
            lastShiftTap = nil
            switch page {
            case .letters: page = .numbers
            case .numbers: page = sender.spec.title == "#+=" ? .symbols : .letters
            case .symbols: page = sender.spec.title == "123" ? .numbers : .letters
            }
            rebuild()
        }
    }
}

private struct KeySpec {
    enum Action {
        case insert(String)
        case delete
        case shift
        case mode
        case spacer
    }

    let row: Int
    let units: CGFloat
    let title: String
    let action: Action
    var symbol: String? = nil
    var isSelected = false

    var isSpacer: Bool {
        if case .spacer = action { return true }
        return false
    }
}

private final class KeyView: UIButton {
    let spec: KeySpec
    private let normalFill: UIColor
    private let pressedFill: UIColor

    override var isHighlighted: Bool {
        didSet {
            guard !spec.isSpacer else { return }
            backgroundColor = isHighlighted ? pressedFill : normalFill
            transform = isHighlighted ? CGAffineTransform(scaleX: 0.96, y: 0.96) : .identity
        }
    }

    init(spec: KeySpec, dark: Bool) {
        self.spec = spec
        normalFill = Self.fill(spec: spec, dark: dark)
        pressedFill = KeyboardChromeTokens.pressedKeyFill(dark: dark)
        super.init(frame: .zero)
        isUserInteractionEnabled = !spec.isSpacer
        isAccessibilityElement = !spec.isSpacer
        accessibilityLabel = spec.title
        accessibilityIdentifier = spec.title == "Murmur" ? "murmur.keyboard.space" : nil
        layer.cornerRadius = KeyboardChromeTokens.keyCornerRadius
        titleLabel?.font = .systemFont(
            ofSize: spec.action.isSpecial ? KeyboardChromeTokens.specialFontSize : KeyboardChromeTokens.letterFontSize,
            weight: .regular
        )
        titleLabel?.adjustsFontSizeToFitWidth = true
        setTitleColor(dark ? .white : .black, for: .normal)
        tintColor = dark ? .white : .black
        if spec.isSelected {
            setTitleColor(dark ? .black : .white, for: .normal)
            tintColor = dark ? .black : .white
        }
        if let symbol = spec.symbol {
            setImage(UIImage(systemName: symbol), for: .normal)
        } else if !spec.isSpacer {
            setTitle(spec.title, for: .normal)
        }
        backgroundColor = normalFill
        if spec.isSpacer { backgroundColor = .clear }
    }

    required init?(coder: NSCoder) { nil }

    private static func fill(spec: KeySpec, dark: Bool) -> UIColor {
        switch spec.action {
        case .insert(" "), .insert("\n"):
            return KeyboardChromeTokens.specialKeyFill(dark: dark)
        case .insert:
            return KeyboardChromeTokens.letterKeyFill(dark: dark)
        case .spacer:
            return .clear
        default:
            if spec.isSelected {
                return dark ? .white : UIColor(white: 0.16, alpha: 1)
            }
            return KeyboardChromeTokens.specialKeyFill(dark: dark)
        }
    }
}

private extension KeySpec.Action {
    var isSpecial: Bool {
        switch self {
        case .insert(let text): return text == " " || text == "\n"
        case .delete, .shift, .mode, .spacer: return true
        }
    }
}

private final class MeterWaveformView: UIView {
    private let bars = (0..<9).map { _ in CALayer() }
    private var recentLevels = Array(repeating: CGFloat.zero, count: 9)

    var level: CGFloat = 0 {
        didSet {
            let bounded = min(1, max(0, level))
            let visible = bounded < 0.025 ? 0 : pow((bounded - 0.025) / 0.975, 0.42)
            recentLevels.removeFirst()
            recentLevels.append(visible)
            setNeedsLayout()
        }
    }

    override var tintColor: UIColor! {
        didSet {
            bars.forEach { $0.backgroundColor = tintColor.cgColor }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        bars.forEach {
            $0.backgroundColor = tintColor.cgColor
            $0.cornerRadius = 2
            layer.addSublayer($0)
        }
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        let widths: CGFloat = 4
        let gap: CGFloat = 7
        let totalWidth = CGFloat(bars.count) * widths + CGFloat(bars.count - 1) * gap
        let startX = (bounds.width - totalWidth) / 2
        let profile: [CGFloat] = [0.66, 0.84, 0.72, 0.96, 1, 0.78, 0.91, 0.7, 0.82]
        CATransaction.begin()
        CATransaction.setDisableActions(UIAccessibility.isReduceMotionEnabled)
        CATransaction.setAnimationDuration(0.1)
        for (index, bar) in bars.enumerated() {
            let historyIndex = min(recentLevels.count - 1, index)
            let energy = recentLevels[historyIndex]
            let response = min(1, energy * (0.92 + CGFloat(index % 3) * 0.12))
            let height = response == 0 ? 4 : max(7, bounds.height * profile[index] * response)
            bar.frame = CGRect(
                x: startX + CGFloat(index) * (widths + gap),
                y: (bounds.height - height) / 2,
                width: widths,
                height: height
            )
            bar.cornerRadius = widths / 2
        }
        CATransaction.commit()
    }
}
