import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Apple-shaped QWERTY chrome. Murmur dictation replaces the keys while a take is active.
final class KeyboardChromeView: UIView {
    var onMic: (() -> Void)?
    var onCancel: (() -> Void)?
    var onDelete: (() -> Void)?
    var onInsert: ((String) -> Void)?
    var onCandidate: ((Int) -> Void)?
    var onGif: (() -> Void)?
    var onGifSelect: ((GiphyClient.GIF) -> Void)?
    var onSwipe: (([String]) -> Void)?
    var onNeedsHeightChange: (() -> Void)?
    var swipeLexicon: [String] = FrequencyList.words
    var swipeCasing: [String: String] = [:]
    var swipeTypingEnabled = false

    private enum Page { case letters, numbers, symbols, emoji }

    private let topBar = AccessoryBarView()
    private let grid = UIView()

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
    private let gifTray = GiphyTrayView()
    private let emojiPicker = EmojiPickerView()

    private var page: Page = .letters
    private enum ShiftState { case off, once, locked }
    private var shiftState: ShiftState = .once
    private var lastShiftTap: ContinuousClock.Instant?
    private var longPressConsumed = false
    private var dark = true
    private var micEnabled = true
    private var micHidden = false
    private var sessionActive = false
    private var returnTitle = "return"
    private var keyViews: [KeyView] = []
    private var deleteRepeatTask: Task<Void, Never>?
    private let keyHaptic = UIImpactFeedbackGenerator(style: .light)
    private var gifTrayVisible = false
    private var gifAvailable = false
    private var gifReason = "GIFs need Full Access and a Giphy key"
    private var letterGeometry: [SwipeTypingEngine.KeyCenter] = []
    private var letterKeyWidth: CGFloat = 30
    private let letterSwipe = LetterSwipeRecognizer()
    private let swipeTrail = SwipeTrailView()
    private let keyPreview = KeyPreviewView()
    private let modeSlide = ModeSlideRecognizer()
    private var metrics = KeyboardChromeMetrics.metrics(width: 430, isLandscape: false)
    private var slideToTypeActive = false
    private var diacriticActive = false
    private var lastPreviewCount = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureChrome()
        applyColors()
        rebuild()
    }

    required init?(coder: NSCoder) { nil }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === letterSwipe {
            return swipeTypingEnabled
                && page == .letters
                && !sessionActive
                && !grid.isHidden
                && !gifTrayVisible
                && !slideToTypeActive
                && !diacriticActive
                && !letterGeometry.isEmpty
        }
        if gestureRecognizer is UILongPressGestureRecognizer {
            if letterSwipe.state == .began || letterSwipe.state == .changed { return false }
            if slideToTypeActive { return false }
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

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
        if on {
            gifTrayVisible = false
            gifTray.resetMode()
            if page == .emoji {
                page = .letters
                emojiPicker.resetMode()
            }
        }
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

    func setCandidates(_ words: [String], quoted: Set<String> = []) {
        topBar.setCandidates(words, quoted: quoted)
    }

    func setFullAccess(_ ok: Bool) {
        micEnabled = ok
        topBar.setMicEnabled(ok)
        refreshGifControl()
    }

    func setGifAvailable(_ available: Bool, reason: String) {
        gifAvailable = available
        gifReason = reason
        if !available {
            gifTrayVisible = false
            gifTray.resetMode()
        }
        refreshGifControl()
    }

    func setGiphyAPIKey(_ key: String) {
        gifTray.apiKey = key
    }

    func setGifTrayVisible(_ visible: Bool) {
        if visible, page == .emoji {
            page = .letters
            emojiPicker.resetMode()
        }
        gifTrayVisible = visible && gifAvailable && !sessionActive && !micHidden
        if gifTrayVisible {
            gifTray.appear()
        } else {
            gifTray.resetMode()
        }
        updateVisibility()
        onNeedsHeightChange?()
    }

    var isGifTrayVisible: Bool { gifTrayVisible }

    /// Extra input-view height while GIF search sits above full-size keys.
    var gifSearchExtraHeight: CGFloat {
        guard gifTrayVisible, gifTray.isSearchMode else { return 0 }
        return metrics.gifSearchPanelHeight + 4
    }

    func handleGifTyping(_ text: String) -> Bool {
        guard gifTrayVisible else { return false }
        gifTray.insertSearchText(text)
        updateVisibility()
        setNeedsLayout()
        return true
    }

    func handleGifDelete() -> Bool {
        guard gifTrayVisible else { return false }
        if gifTray.isSearchMode || !gifTray.searchText.isEmpty {
            gifTray.deleteSearchText()
            updateVisibility()
            setNeedsLayout()
            return true
        }
        return false
    }

    func handleEmojiTyping(_ text: String) -> Bool {
        guard page == .emoji, emojiPicker.isSearchMode else { return false }
        guard text.unicodeScalars.allSatisfy(\.isASCII) else { return false }
        emojiPicker.insertSearchText(text)
        setNeedsLayout()
        return true
    }

    func handleEmojiDelete() -> Bool {
        guard page == .emoji else { return false }
        if EmojiSearchRouting.consumeDelete(
            isSearchMode: emojiPicker.isSearchMode,
            searchIsEmpty: emojiPicker.searchText.isEmpty
        ) {
            _ = emojiPicker.deleteSearchText()
            setNeedsLayout()
            return true
        }
        return false
    }

    func setSecure(_ secure: Bool) {
        micHidden = secure
        if secure {
            gifTrayVisible = false
            gifTray.resetMode()
            setStatus("Dictation off in secure fields")
        }
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
        let side = metrics.sideInset
        let topHeight = metrics.accessoryHeight
        let bottomInset = metrics.bottomInset

        topBar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: topHeight)

        let showEmoji = page == .emoji && !sessionActive
        if showEmoji {
            if emojiPicker.isSearchMode {
                let needed = emojiPicker.searchPanelHeight(forWidth: bounds.width)
                let keyRow = min(36, metrics.letterKeyHeight)
                let reservedKeys = 3 * keyRow + 2 * metrics.rowGap
                let maxPanel = max(0, bounds.height - bottomInset - reservedKeys)
                let panel = min(needed, maxPanel)
                emojiPicker.frame = CGRect(x: 0, y: 0, width: bounds.width, height: panel)
                grid.frame = CGRect(
                    x: side,
                    y: panel,
                    width: bounds.width - side * 2,
                    height: max(0, bounds.height - bottomInset - panel)
                )
            } else {
                emojiPicker.frame = CGRect(
                    x: 0,
                    y: 0,
                    width: bounds.width,
                    height: max(0, bounds.height - bottomInset)
                )
                grid.frame = .zero
            }
            gifTray.frame = .zero
        } else {
            emojiPicker.frame = .zero
            let gridBottom = bounds.height - bottomInset
            let gridFrame = CGRect(
                x: side,
                y: topBar.frame.maxY,
                width: bounds.width - side * 2,
                height: max(0, gridBottom - topBar.frame.maxY)
            )
            if gifTrayVisible {
                if gifTray.isSearchMode {
                    let trayGridGap: CGFloat = 4
                    let panel = metrics.gifSearchPanelHeight
                    gifTray.frame = CGRect(
                        x: gridFrame.minX,
                        y: topBar.frame.maxY,
                        width: gridFrame.width,
                        height: panel
                    )
                    grid.frame = CGRect(
                        x: gridFrame.minX,
                        y: gifTray.frame.maxY + trayGridGap,
                        width: gridFrame.width,
                        height: max(0, bounds.height - bottomInset - gifTray.frame.maxY - trayGridGap)
                    )
                } else {
                    gifTray.frame = gridFrame
                    grid.frame = gridFrame
                }
            } else {
                gifTray.frame = .zero
                grid.frame = gridFrame
            }
        }
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

        layoutKeys()
        bringSubviewToFront(gifTray)
        bringSubviewToFront(emojiPicker)
        bringSubviewToFront(keyPreview)
        if !errorBanner.isHidden {
            bringSubviewToFront(errorBanner)
        }
    }

    func applyMetrics(_ metrics: KeyboardChromeMetrics) {
        guard self.metrics != metrics else { return }
        self.metrics = metrics
        rebuild()
    }

    private func configureChrome() {
        applyChromeShape()
        addSubview(topBar)
        topBar.onMic = { [weak self] in self?.onMic?() }
        topBar.onCandidate = { [weak self] index in self?.onCandidate?(index) }
        topBar.onGif = { [weak self] in self?.onGif?() }
        addSubview(grid)
        swipeTrail.isUserInteractionEnabled = false
        swipeTrail.isOpaque = false
        swipeTrail.backgroundColor = .clear
        swipeTrail.contentMode = .redraw
        grid.addSubview(swipeTrail)
        letterSwipe.addTarget(self, action: #selector(handleLetterSwipe(_:)))
        letterSwipe.letterAt = { [weak self] point in self?.letterAt(point) }
        letterSwipe.onPathChanged = { [weak self] points, recognized in
            guard recognized else { return }
            self?.swipeTrail.points = points
            self?.previewSwipe(path: points)
        }
        letterSwipe.isSwipeEnabled = { [weak self] in
            guard let self else { return false }
            return self.swipeTypingEnabled
                && self.page == .letters
                && !self.sessionActive
                && !self.grid.isHidden
                && !self.gifTrayVisible
                && !self.slideToTypeActive
                && !self.diacriticActive
                && !self.letterGeometry.isEmpty
        }
        letterSwipe.delegate = self
        letterSwipe.cancelsTouchesInView = true
        grid.addGestureRecognizer(letterSwipe)
        modeSlide.canBegin = { [weak self] point in
            self?.canBeginModeSlide(at: point) ?? false
        }
        modeSlide.homeFrameAt = { [weak self] point in
            self?.modeKeyFrame(at: point) ?? .zero
        }
        modeSlide.onSlidOff = { [weak self] in
            self?.beginSlideToType()
        }
        modeSlide.onMoved = { [weak self] point in
            self?.updateSlideHighlight(at: point)
        }
        modeSlide.onFinished = { [weak self] didLeave, point, cancelled in
            self?.endSlideToType(didLeave: didLeave, at: point, cancelled: cancelled)
        }
        modeSlide.cancelsTouchesInView = true
        addGestureRecognizer(modeSlide)
        keyPreview.isUserInteractionEnabled = false
        addSubview(keyPreview)
        addSubview(gifTray)
        gifTray.isHidden = true
        gifTray.onSelect = { [weak self] gif in self?.onGifSelect?(gif) }
        gifTray.onModeChange = { [weak self] in
            self?.updateVisibility()
            self?.onNeedsHeightChange?()
            self?.setNeedsLayout()
        }
        addSubview(emojiPicker)
        emojiPicker.isHidden = true
        emojiPicker.onSelect = { [weak self] glyph in self?.onInsert?(glyph) }
        emojiPicker.onABC = { [weak self] in
            guard let self else { return }
            self.page = .letters
            self.emojiPicker.resetMode()
            self.rebuild()
        }
        emojiPicker.onDelete = { [weak self] in self?.onDelete?() }
        emojiPicker.onSearchModeChange = { [weak self] in
            self?.rebuild()
            self?.updateVisibility()
            self?.setNeedsLayout()
        }
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
        let showTray = gifTrayVisible && !showPanel && !micHidden
        let searchTyping = showTray && gifTray.isSearchMode
        let showEmoji = page == .emoji && !showPanel
        listeningPanel.isHidden = !showPanel
        topBar.isHidden = showPanel || showEmoji
        grid.isHidden = showPanel || (showTray && !searchTyping) || (showEmoji && !emojiPicker.isSearchMode)
        gifTray.isHidden = !showTray
        emojiPicker.isHidden = !showEmoji
        topBar.setMicHidden(micHidden)
        refreshGifControl()
        setNeedsLayout()
    }

    private func refreshGifControl() {
        let enabled = gifAvailable && !micHidden && !sessionActive
        topBar.setGifEnabled(enabled, reason: gifReason)
        topBar.setGifTrayOpen(gifTrayVisible && enabled)
    }

    private func applyChromeShape() {
        let radius = KeyboardChromeTokens.chromeCornerRadius
        layer.cornerRadius = radius
        layer.maskedCorners = KeyboardChromeTokens.chromeTopCorners
        layer.cornerCurve = .continuous
        clipsToBounds = true
    }

    private func applyColors() {
        backgroundColor = KeyboardChromeTokens.keyboardBackdrop(dark: dark)
        topBar.setAppearance(dark: dark)
        gifTray.setAppearance(dark: dark)
        emojiPicker.setAppearance(dark: dark)

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
        keyPreview.applyAppearance(dark: dark)
    }

    private func rebuild() {
        deleteRepeatTask?.cancel()
        deleteRepeatTask = nil
        if !diacriticActive && !slideToTypeActive {
            keyPreview.dismiss()
        }
        keyViews.forEach { $0.removeFromSuperview() }
        keyViews = specs().map { spec in
            let key = KeyView(spec: spec, dark: dark, metrics: metrics)
            if case .delete = spec.action {
                key.addTarget(self, action: #selector(beginDelete(_:)), for: .touchDown)
                key.addTarget(
                    self,
                    action: #selector(endDelete(_:)),
                    for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit]
                )
            } else if case .mode = spec.action, page == .letters, spec.title == "123" {
                key.addTarget(self, action: #selector(hapticDown), for: .touchDown)
            } else {
                key.addTarget(self, action: #selector(hapticDown), for: .touchDown)
                key.addTarget(self, action: #selector(tapKey(_:)), for: .touchUpInside)
                key.addTarget(self, action: #selector(keyPreviewDown(_:)), for: .touchDown)
                key.addTarget(
                    self,
                    action: #selector(keyPreviewEnd(_:)),
                    for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit]
                )
            }
            if spec.longPressInsert != nil {
                let hold = UILongPressGestureRecognizer(target: self, action: #selector(longPressKey(_:)))
                hold.minimumPressDuration = 0.35
                key.addGestureRecognizer(hold)
            } else if case .insert(let text) = spec.action, !KeyDiacriticMap.alternatives(for: text).isEmpty {
                let hold = UILongPressGestureRecognizer(target: self, action: #selector(diacriticPress(_:)))
                hold.minimumPressDuration = 0.4
                hold.delegate = self
                key.addGestureRecognizer(hold)
            }
            grid.addSubview(key)
            return key
        }
        grid.bringSubviewToFront(swipeTrail)
        applyColors()
        updateVisibility()
        layoutKeys()
        bringSubviewToFront(keyPreview)
    }

    private func layoutKeys() {
        let rows = Dictionary(grouping: keyViews) { $0.spec.row }
        let gap = metrics.keyGap
        let rowGap = metrics.rowGap
        let maxRow = keyViews.map(\.spec.row).max() ?? 3
        let rowCount = CGFloat(maxRow + 1)
        let fitted = (grid.bounds.height - rowGap * (rowCount - 1)) / rowCount
        let height = min(metrics.letterKeyHeight, max(32, fitted))
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
        swipeTrail.frame = grid.bounds
        refreshLetterGeometry()
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
        case .emoji:
            return emojiPicker.isSearchMode ? searchLetterSpecs() : []
        }
    }

    private func letterSpecs() -> [KeySpec] {
        let letters = [Array("qwertyuiop"), Array("asdfghjkl"), Array("zxcvbnm")]
        var result: [KeySpec] = []
        for (row, chars) in letters.enumerated() {
            if row == 1 {
                result.append(KeySpec(row: 1, units: metrics.asdfSpacerUnits, title: "", action: .spacer))
            }
            if row == 2 {
                let symbol = shiftState == .locked ? "capslock.fill" : (shiftState == .off ? "shift" : "shift.fill")
                result.append(KeySpec(
                    row: 2,
                    units: metrics.shiftUnits,
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
            if row == 1 {
                result.append(KeySpec(row: 1, units: metrics.asdfSpacerUnits, title: "", action: .spacer))
            }
            if row == 2 {
                result.append(KeySpec(
                    row: 2,
                    units: metrics.shiftUnits,
                    title: "delete",
                    action: .delete,
                    symbol: "delete.backward"
                ))
            }
        }
        return result + bottom(modeTitle: "123")
    }

    private func searchLetterSpecs() -> [KeySpec] {
        let letters = [Array("qwertyuiop"), Array("asdfghjkl"), Array("zxcvbnm")]
        var result: [KeySpec] = []
        for (row, chars) in letters.enumerated() {
            if row == 1 {
                result.append(KeySpec(row: 1, units: metrics.asdfSpacerUnits, title: "", action: .spacer))
            }
            if row == 2 {
                result.append(KeySpec(
                    row: 2,
                    units: metrics.shiftUnits,
                    title: "space",
                    action: .insert(" ")
                ))
            }
            for ch in chars {
                result.append(KeySpec(row: row, units: 1, title: String(ch), action: .insert(String(ch))))
            }
            if row == 1 {
                result.append(KeySpec(row: 1, units: metrics.asdfSpacerUnits, title: "", action: .spacer))
            }
            if row == 2 {
                result.append(KeySpec(
                    row: 2,
                    units: metrics.shiftUnits,
                    title: "delete",
                    action: .delete,
                    symbol: "delete.backward"
                ))
            }
        }
        return result
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

    private func bottom(modeTitle: String, includeEmojiKey: Bool = true) -> [KeySpec] {
        var keys: [KeySpec] = [
            KeySpec(row: 3, units: metrics.modeUnits, title: modeTitle, action: .mode)
        ]
        if includeEmojiKey {
            keys.append(
                KeySpec(
                    row: 3,
                    units: metrics.emojiUnits,
                    title: "emoji",
                    action: .emoji
                )
            )
        }
        keys.append(
            KeySpec(
                row: 3,
                units: includeEmojiKey ? metrics.spaceUnits : metrics.spaceUnitsWithoutEmoji,
                title: "space",
                action: .insert(" ")
            )
        )
        let returnIsDefault = returnTitle == "return"
        keys.append(
            KeySpec(
                row: 3,
                units: metrics.returnUnits,
                title: returnTitle,
                action: .insert("\n"),
                symbol: returnIsDefault ? "return.left" : nil,
                isProminent: !returnIsDefault
            )
        )
        return keys
    }

    @objc private func hapticDown() {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        keyHaptic.impactOccurred(intensity: 0.55)
    }

    @objc private func tapMic() { onMic?() }
    @objc private func tapCancel() { onCancel?() }
    @objc private func tapDismissError() { dismissError() }

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

    @objc private func handleLetterSwipe(_ gesture: LetterSwipeRecognizer) {
        switch gesture.state {
        case .began:
            hapticDown()
            swipeTrail.points = gesture.points
            highlightSwipe(gesture.sampledLetters)
            previewSwipe(path: gesture.points)
        case .changed:
            swipeTrail.points = gesture.points
            highlightSwipe(gesture.sampledLetters)
            previewSwipe(path: gesture.points)
        case .ended:
            highlightSwipe([])
            lastPreviewCount = 0
            commitSwipe(path: gesture.points)
            swipeTrail.fadeOut()
        default:
            highlightSwipe([])
            lastPreviewCount = 0
            swipeTrail.clear()
        }
    }

    private func previewSwipe(path: [CGPoint]) {
        guard path.count - lastPreviewCount >= 2 || lastPreviewCount == 0 else { return }
        lastPreviewCount = path.count
        let words = rankedSwipe(path: path)
        topBar.setCandidates(words.map { applySwipeCase($0) })
    }

    private func commitSwipe(path: [CGPoint]) {
        let travel = SwipeTypingEngine.pathLength(path)
        let letters = SwipeTypingEngine.keySequence(
            path: path,
            keys: letterGeometry,
            keyWidth: letterKeyWidth
        )
        guard SwipeTypingEngine.isDeliberateSwipe(
            travel: travel,
            uniqueLetters: letters.count,
            keyWidth: letterKeyWidth
        ) else { return }
        let words = rankedSwipe(path: path)
        guard !words.isEmpty else { return }
        onSwipe?(words.map { applySwipeCase($0) })
        if shiftState == .once {
            shiftState = .off
            rebuild()
        }
    }

    private func rankedSwipe(path: [CGPoint]) -> [String] {
        let lexicon = swipeLexicon.isEmpty ? FrequencyList.words : swipeLexicon
        return SwipeTypingEngine.candidates(
            path: path,
            keys: letterGeometry,
            words: lexicon,
            keyWidth: letterKeyWidth,
            limit: 3
        )
    }

    private func applySwipeCase(_ word: String) -> String {
        let cased: String
        if shiftState == .locked {
            cased = word.uppercased()
        } else if let preferred = swipeCasing[word.lowercased()] {
            cased = preferred
        } else if FrequencyList.nameSet.contains(word.lowercased()), let first = word.first {
            cased = String(first).uppercased() + word.dropFirst()
        } else if shiftState == .once, let first = word.first {
            cased = String(first).uppercased() + word.dropFirst()
        } else {
            cased = word
        }
        return AutocorrectEngine.capitalizedIContraction(cased)
    }

    private func letterAt(_ point: CGPoint) -> Character? {
        SwipeTypingEngine.nearestLetter(
            at: point,
            keys: letterGeometry,
            maxDistance: letterKeyWidth * 2.2
        )
    }

    private func refreshLetterGeometry() {
        var width: CGFloat = 30
        letterGeometry = keyViews.compactMap { key in
            guard case .insert(let text) = key.spec.action,
                  text.count == 1,
                  let character = text.lowercased().first,
                  character.isLetter else { return nil }
            width = key.frame.width
            return SwipeTypingEngine.KeyCenter(
                letter: character,
                point: CGPoint(x: key.frame.midX, y: key.frame.midY),
                frame: key.frame
            )
        }
        letterKeyWidth = max(width, 8)
        letterSwipe.keyWidth = letterKeyWidth
    }

    private func highlightSwipe(_ letters: [Character]) {
        let set = Set(letters)
        for key in keyViews {
            guard case .insert(let text) = key.spec.action,
                  let character = text.lowercased().first,
                  character.isLetter else { continue }
            key.isHighlighted = set.contains(character)
        }
    }

    @objc private func tapKey(_ sender: KeyView) {
        if longPressConsumed {
            longPressConsumed = false
            return
        }
        switch sender.spec.action {
        case .spacer:
            return
        case .insert(let text):
            lastShiftTap = nil
            onInsert?(text)
            if page == .letters, text.count == 1, text != " ", text != "\n",
               !".,'!?".contains(text), shiftState == .once {
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
            case .emoji: page = .letters
            }
            rebuild()
        case .emoji:
            UIDevice.current.playInputClick()
            lastShiftTap = nil
            gifTrayVisible = false
            gifTray.resetMode()
            page = .emoji
            emojiPicker.resetMode()
            rebuild()
            onNeedsHeightChange?()
        }
    }

    @objc private func keyPreviewDown(_ sender: KeyView) {
        guard shouldShowPreview(for: sender.spec) else { return }
        let frame = sender.convert(sender.bounds, to: self)
        keyPreview.showPopup(glyph: sender.spec.title, keyFrame: frame, chromeBounds: bounds, dark: dark)
        bringSubviewToFront(keyPreview)
    }

    @objc private func keyPreviewEnd(_: KeyView) {
        if !diacriticActive {
            keyPreview.dismiss()
        }
    }

    private func shouldShowPreview(for spec: KeySpec) -> Bool {
        if UIAccessibility.isReduceMotionEnabled { return false }
        if slideToTypeActive || diacriticActive { return false }
        guard case .insert(let text) = spec.action, text.count == 1 else { return false }
        if page == .numbers, spec.row == 0, text.first?.isNumber == true { return true }
        if page == .letters, (spec.row == 1 || spec.row == 2), text.first?.isLetter == true { return true }
        return false
    }

    private func canBeginModeSlide(at point: CGPoint) -> Bool {
        guard page == .letters, !sessionActive, !grid.isHidden, !gifTrayVisible, !diacriticActive else {
            return false
        }
        guard let key = keyAtChromePoint(point) else { return false }
        if case .mode = key.spec.action { return key.spec.title == "123" }
        return false
    }

    private func modeKeyFrame(at point: CGPoint) -> CGRect {
        guard let key = keyAtChromePoint(point) else { return .zero }
        return key.convert(key.bounds, to: self)
    }

    private func beginSlideToType() {
        slideToTypeActive = true
        letterSwipe.isEnabled = false
        page = .numbers
        rebuild()
    }

    private func updateSlideHighlight(at point: CGPoint) {
        let hit = slideInsertKey(at: point)
        for key in keyViews {
            guard case .insert(let text) = key.spec.action, text != " ", text != "\n" else {
                key.isHighlighted = false
                continue
            }
            key.isHighlighted = hit === key
        }
    }

    private func endSlideToType(didLeave: Bool, at point: CGPoint, cancelled: Bool) {
        letterSwipe.isEnabled = true
        slideToTypeActive = false
        if cancelled {
            page = .letters
            rebuild()
            return
        }
        if didLeave {
            if let key = slideInsertKey(at: point), case .insert(let text) = key.spec.action {
                onInsert?(text)
            }
            page = .letters
            rebuild()
        } else {
            page = .numbers
            rebuild()
        }
    }

    private func slideInsertKey(at point: CGPoint) -> KeyView? {
        guard let key = keyAtChromePoint(point) else { return nil }
        guard case .insert(let text) = key.spec.action, text != " ", text != "\n" else { return nil }
        return key
    }

    private func keyAtChromePoint(_ point: CGPoint) -> KeyView? {
        let gridPoint = grid.convert(point, from: self)
        return keyViews.first { key in
            !key.spec.isSpacer && key.frame.contains(gridPoint)
        }
    }

    @objc private func diacriticPress(_ gesture: UILongPressGestureRecognizer) {
        guard let key = gesture.view as? KeyView,
              case .insert(let text) = key.spec.action else { return }
        let alts = KeyDiacriticMap.alternatives(for: text)
        guard !alts.isEmpty else { return }
        let point = gesture.location(in: self)
        switch gesture.state {
        case .began:
            if letterSwipe.state == .began || letterSwipe.state == .changed { return }
            diacriticActive = true
            letterSwipe.isEnabled = false
            longPressConsumed = true
            hapticDown()
            key.isHighlighted = true
            let frame = key.convert(key.bounds, to: self)
            let preferBelow = key.spec.row == 0
            keyPreview.showStrip(
                items: alts,
                keyFrame: frame,
                preferBelow: preferBelow,
                chromeBounds: bounds,
                dark: dark
            )
            bringSubviewToFront(keyPreview)
        case .changed:
            guard diacriticActive else { return }
            keyPreview.select(at: point)
        case .ended:
            guard diacriticActive else { return }
            let glyph = keyPreview.selectedGlyph
            let shouldUnshift = page == .letters && shiftState == .once && glyph != nil
            finishDiacritic(key)
            if let glyph {
                onInsert?(glyph)
                if shouldUnshift {
                    shiftState = .off
                    rebuild()
                }
            }
            DispatchQueue.main.async { [weak self] in
                self?.longPressConsumed = false
            }
        default:
            if diacriticActive {
                longPressConsumed = false
                finishDiacritic(key)
            }
        }
    }

    private func finishDiacritic(_ key: KeyView) {
        diacriticActive = false
        letterSwipe.isEnabled = true
        key.isHighlighted = false
        keyPreview.dismiss()
    }

    @objc private func longPressKey(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began,
              let key = gesture.view as? KeyView,
              let alt = key.spec.longPressInsert else { return }
        longPressConsumed = true
        hapticDown()
        key.isHighlighted = false
        onInsert?(alt)
    }
}

private struct KeySpec {
    enum Action {
        case insert(String)
        case delete
        case shift
        case mode
        case emoji
        case spacer
    }

    let row: Int
    let units: CGFloat
    let title: String
    let action: Action
    var symbol: String? = nil
    var isSelected = false
    var isProminent = false
    var longPressInsert: String? = nil

    var isSpacer: Bool {
        if case .spacer = action { return true }
        return false
    }
}

private final class KeyView: UIButton {
    let spec: KeySpec
    private let face = UIView()
    private let normalFill: UIColor
    private let pressedFill: UIColor
    private let lipColor: UIColor

    override var isHighlighted: Bool {
        didSet {
            guard !spec.isSpacer else { return }
            face.backgroundColor = isHighlighted ? pressedFill : normalFill
        }
    }

    init(spec: KeySpec, dark: Bool, metrics: KeyboardChromeMetrics) {
        self.spec = spec
        normalFill = Self.fill(spec: spec, dark: dark)
        pressedFill = spec.isProminent
            ? UIColor.systemBlue.withAlphaComponent(0.78)
            : KeyboardChromeTokens.pressedKeyFill(dark: dark)
        lipColor = Self.lip(spec: spec, dark: dark)
        super.init(frame: .zero)
        isUserInteractionEnabled = !spec.isSpacer
        isAccessibilityElement = !spec.isSpacer
        accessibilityLabel = spec.title
        if case .insert(" ") = spec.action {
            accessibilityIdentifier = "murmur.keyboard.space"
        } else if case .emoji = spec.action {
            accessibilityIdentifier = "murmur.keyboard.emoji"
        }
        layer.cornerRadius = KeyboardChromeTokens.keyCornerRadius
        layer.cornerCurve = .continuous
        clipsToBounds = true
        face.isUserInteractionEnabled = false
        face.layer.cornerRadius = KeyboardChromeTokens.keyCornerRadius
        face.layer.cornerCurve = .continuous
        face.clipsToBounds = true
        insertSubview(face, at: 0)
        face.layer.zPosition = -1
        titleLabel?.font = .systemFont(
            ofSize: spec.action.isSpecial ? metrics.specialFont : metrics.letterFont,
            weight: spec.action.isSpecial ? .medium : .regular
        )
        titleLabel?.adjustsFontSizeToFitWidth = true
        let glyph = spec.isProminent ? UIColor.white : KeyboardChromeTokens.glyphColor(dark: dark)
        if spec.isSelected {
            setTitleColor(dark ? .black : .white, for: .normal)
            tintColor = dark ? .black : .white
        } else {
            setTitleColor(glyph, for: .normal)
            tintColor = glyph
        }
        if let symbol = spec.symbol {
            let config = UIImage.SymbolConfiguration(pointSize: metrics.specialFont, weight: .medium)
            let names = [symbol, "globe"]
            let image = names.compactMap {
                UIImage(systemName: $0, withConfiguration: config)?.withRenderingMode(.alwaysTemplate)
            }.first
            if let image {
                setImage(image, for: .normal)
                setTitle(nil, for: .normal)
            } else {
                setTitle(spec.title, for: .normal)
            }
        } else if case .emoji = spec.action {
            setImage(nil, for: .normal)
            setTitle("😊", for: .normal)
            titleLabel?.font = .systemFont(ofSize: metrics.letterFont, weight: .regular)
        } else if case .insert(" ") = spec.action {
            setTitle(nil, for: .normal)
        } else if !spec.isSpacer {
            setTitle(spec.title, for: .normal)
        }
        backgroundColor = spec.isSpacer ? .clear : lipColor
        face.backgroundColor = spec.isSpacer ? .clear : normalFill
        if spec.isSpacer { backgroundColor = .clear }
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !spec.isSpacer else {
            face.frame = .zero
            return
        }
        face.frame = CGRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - 1))
        sendSubviewToBack(face)
        if let imageView {
            bringSubviewToFront(imageView)
        }
        if let titleLabel {
            bringSubviewToFront(titleLabel)
        }
    }

    private static func fill(spec: KeySpec, dark: Bool) -> UIColor {
        if spec.isProminent {
            return .systemBlue
        }
        switch spec.action {
        case .insert(" "):
            return KeyboardChromeTokens.letterKeyFill(dark: dark)
        case .insert("\n"):
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

    private static func lip(spec: KeySpec, dark: Bool) -> UIColor {
        if spec.isProminent {
            return UIColor.systemBlue.withAlphaComponent(0.72)
        }
        if spec.isSelected {
            return dark ? UIColor(white: 0.72, alpha: 1) : UIColor(white: 0.05, alpha: 1)
        }
        return KeyboardChromeTokens.keyLip(dark: dark, special: spec.action.isSpecial)
    }
}

private extension KeySpec.Action {
    var isSpecial: Bool {
        switch self {
        case .insert(let text): return text == "\n"
        case .delete, .shift, .mode, .emoji, .spacer: return true
        }
    }
}

extension KeyboardChromeView: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        guard gestureRecognizer === letterSwipe else { return true }
        var view: UIView? = touch.view
        while let current = view, current !== grid {
            if let key = current as? KeyView {
                switch key.spec.action {
                case .insert(let text) where text == " " || text == "\n":
                    return false
                case .shift, .delete, .mode, .emoji, .spacer:
                    return false
                default:
                    return true
                }
            }
            view = current.superview
        }
        return true
    }
}

/// Press 123, drag onto a numbers-page key, release inserts and returns to letters.
/// No swipe trail. If the finger never leaves 123, this is a normal page switch.
private final class ModeSlideRecognizer: UIGestureRecognizer {
    var canBegin: ((CGPoint) -> Bool)?
    var homeFrameAt: ((CGPoint) -> CGRect)?
    var onSlidOff: (() -> Void)?
    var onMoved: ((CGPoint) -> Void)?
    var onFinished: ((Bool, CGPoint, Bool) -> Void)?

    private var home = CGRect.zero
    private var left = false
    private var lastPoint = CGPoint.zero

    override func reset() {
        super.reset()
        home = .zero
        left = false
        lastPoint = .zero
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first, let view else {
            state = .failed
            return
        }
        let point = touch.location(in: view)
        guard canBegin?(point) == true else {
            state = .failed
            return
        }
        lastPoint = point
        home = homeFrameAt?(point) ?? .zero
        left = false
        state = .possible
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first, let view else { return }
        let point = touch.location(in: view)
        lastPoint = point
        if !left && !home.insetBy(dx: -8, dy: -8).contains(point) {
            left = true
            state = .began
            onSlidOff?()
            onMoved?(point)
        } else if left, state == .began || state == .changed {
            state = .changed
            onMoved?(point)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if let touch = touches.first, let view {
            lastPoint = touch.location(in: view)
        }
        if left {
            onMoved?(lastPoint)
        }
        onFinished?(left, lastPoint, false)
        state = left ? .ended : .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        if state == .possible || state == .began || state == .changed {
            onFinished?(left, lastPoint, true)
        }
        state = .cancelled
    }
}

/// Coral finger trail. Fades toward the fingertip; older ink stays dimmer.
private final class SwipeTrailView: UIView {
    var points: [CGPoint] = [] {
        didSet { setNeedsDisplay() }
    }

    override func draw(_ rect: CGRect) {
        guard points.count >= 2 else { return }
        let lastIndex = points.count - 1
        for index in 1...lastIndex {
            let path = UIBezierPath()
            path.move(to: points[index - 1])
            path.addLine(to: points[index])
            path.lineWidth = 6.5
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            let t = CGFloat(index) / CGFloat(lastIndex)
            KeyboardChromeTokens.coral.withAlphaComponent(0.18 + 0.72 * t).setStroke()
            path.stroke()
        }
        if let last = points.last {
            let blob = UIBezierPath(ovalIn: CGRect(x: last.x - 4, y: last.y - 4, width: 8, height: 8))
            KeyboardChromeTokens.coralLight.withAlphaComponent(0.85).setFill()
            blob.fill()
        }
    }

    func clear() {
        layer.removeAllAnimations()
        alpha = 1
        points = []
    }

    func fadeOut() {
        points = []
        setNeedsDisplay()
        alpha = 1
    }
}

/// Stays `.possible` until the finger crosses two letter keys and ~16pt, so taps still fire.
private final class LetterSwipeRecognizer: UIGestureRecognizer {
    var letterAt: ((CGPoint) -> Character?)?
    var isSwipeEnabled: () -> Bool = { true }
    var onPathChanged: (([CGPoint], Bool) -> Void)?
    var keyWidth: CGFloat = 30
    private(set) var points: [CGPoint] = []
    private(set) var sampledLetters: [Character] = []
    private var start = CGPoint.zero

    override func reset() {
        super.reset()
        points = []
        sampledLetters = []
        start = .zero
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard isSwipeEnabled() else {
            state = .failed
            return
        }
        guard let touch = touches.first, let view else {
            state = .failed
            return
        }
        start = touch.location(in: view)
        points = [start]
        if let letter = letterAt?(start) {
            sampledLetters = [letter]
            state = .possible
        } else {
            state = .failed
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first, let view else { return }
        let point = touch.location(in: view)
        append(point)
        let dx = point.x - start.x
        let dy = point.y - start.y
        let distance = (dx * dx + dy * dy).squareRoot()
        if state == .possible {
            let travel = SwipeTypingEngine.pathLength(points)
            if SwipeTypingEngine.isDeliberateSwipe(
                travel: max(distance, travel),
                uniqueLetters: sampledLetters.count,
                keyWidth: keyWidth
            ) {
                state = .began
            }
        } else if state == .began || state == .changed {
            state = .changed
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if let touch = touches.first, let view {
            append(touch.location(in: view))
        }
        if state == .began || state == .changed {
            state = .ended
        } else {
            state = .failed
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .cancelled
    }

    private func append(_ point: CGPoint) {
        points.append(point)
        if points.count > 256 {
            points = stride(from: 0, to: points.count, by: 2).map { points[$0] }
        }
        if let letter = letterAt?(point), sampledLetters.last != letter {
            sampledLetters.append(letter)
        }
        let recognized = state == .began || state == .changed
        onPathChanged?(points, recognized)
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
