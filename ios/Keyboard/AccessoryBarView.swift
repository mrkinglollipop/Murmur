import UIKit

/// Top accessory row: GIF · three candidate slots · mic.
final class AccessoryBarView: UIView {
    var onMic: (() -> Void)?
    var onGif: (() -> Void)?
    var onCandidate: ((Int) -> Void)?

    private let gifButton = UIButton(type: .system)
    private let candidateButtons: [UIButton] = (0..<3).map { _ in UIButton(type: .system) }
    private let separators = [UIView(), UIView()]
    private let captionLabel = UILabel()
    private let micButton = UIButton(type: .system)
    private var dark = true
    private var gifEnabled = false
    private var gifTrayOpen = false
    private var caption = ""
    private var candidateWords: [String] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        gifButton.setTitle("GIF", for: .normal)
        gifButton.titleLabel?.font = .systemFont(ofSize: 12, weight: .semibold)
        gifButton.addTarget(self, action: #selector(tapGif), for: .touchUpInside)
        gifButton.accessibilityLabel = "GIFs need Full Access and a Giphy key"
        gifButton.accessibilityIdentifier = "murmur.keyboard.gif"
        gifButton.isEnabled = false
        gifButton.layer.cornerRadius = KeyboardChromeTokens.chipCornerRadius
        addSubview(gifButton)

        for (index, button) in candidateButtons.enumerated() {
            button.titleLabel?.font = .systemFont(ofSize: 17, weight: .regular)
            button.titleLabel?.adjustsFontSizeToFitWidth = true
            button.titleLabel?.minimumScaleFactor = 0.7
            button.layer.cornerRadius = KeyboardChromeTokens.chipCornerRadius
            button.layer.cornerCurve = .continuous
            button.tag = index
            button.addTarget(self, action: #selector(tapCandidate(_:)), for: .touchUpInside)
            button.accessibilityIdentifier = "murmur.keyboard.candidate.\(index)"
            addSubview(button)
        }
        for separator in separators {
            separator.isUserInteractionEnabled = false
            addSubview(separator)
        }

        captionLabel.font = .systemFont(ofSize: 12, weight: .medium)
        captionLabel.textAlignment = .center
        captionLabel.adjustsFontSizeToFitWidth = true
        captionLabel.numberOfLines = 2
        captionLabel.accessibilityIdentifier = "murmur.keyboard.caption"
        addSubview(captionLabel)

        let micConfig = UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        micButton.setImage(UIImage(systemName: "mic.fill", withConfiguration: micConfig), for: .normal)
        micButton.tintColor = .white
        micButton.backgroundColor = KeyboardChromeTokens.coral
        micButton.layer.cornerRadius = 18
        micButton.clipsToBounds = true
        micButton.addTarget(self, action: #selector(tapMic), for: .touchUpInside)
        micButton.accessibilityLabel = "Start dictation"
        micButton.accessibilityIdentifier = "murmur.keyboard.start"
        addSubview(micButton)

        applyColors()
        refreshSlotVisibility()
    }

    required init?(coder: NSCoder) { nil }

    func setAppearance(dark: Bool) {
        self.dark = dark
        applyColors()
    }

    func setGifEnabled(_ enabled: Bool, reason: String? = nil) {
        gifEnabled = enabled
        gifButton.isEnabled = enabled
        gifButton.alpha = enabled ? 1 : 0.45
        if enabled {
            gifButton.accessibilityLabel = gifTrayOpen ? "Close GIFs" : "GIFs"
        } else {
            gifButton.accessibilityLabel = reason ?? "GIFs need Full Access and a Giphy key"
        }
        applyColors()
    }

    func setGifTrayOpen(_ open: Bool) {
        gifTrayOpen = open
        if gifEnabled {
            gifButton.accessibilityLabel = open ? "Close GIFs" : "GIFs"
        }
        applyColors()
        refreshSlotVisibility()
        setNeedsLayout()
    }

    func setCaption(_ text: String) {
        caption = text.trimmingCharacters(in: .whitespacesAndNewlines)
        captionLabel.text = caption
        refreshSlotVisibility()
        setNeedsLayout()
    }

    func setCandidates(_ words: [String], quoted: Set<String> = []) {
        candidateWords = words
        let hasWords = words.contains { !$0.isEmpty }
        if hasWords {
            caption = ""
            captionLabel.text = ""
        }
        for (index, button) in candidateButtons.enumerated() {
            let word = index < words.count ? words[index] : ""
            let title: String
            if word.isEmpty {
                title = ""
            } else if quoted.contains(word.lowercased()) {
                title = "“\(word)”"
            } else {
                title = word
            }
            button.setTitle(title, for: .normal)
            button.isEnabled = !word.isEmpty
            button.accessibilityLabel = word.isEmpty ? "Suggestion slot \(index + 1)" : word
        }
        applyColors()
        refreshSlotVisibility()
    }

    func setMicEnabled(_ enabled: Bool) {
        micButton.isEnabled = enabled
        micButton.alpha = enabled ? 1 : 0.4
    }

    func setMicHidden(_ hidden: Bool) {
        micButton.isHidden = hidden
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let gifSide: CGFloat = 36
        let micSide: CGFloat = micButton.isHidden ? 0 : 36
        gifButton.frame = CGRect(x: 8, y: 2, width: gifSide, height: 40)
        if micSide > 0 {
            micButton.frame = CGRect(
                x: bounds.width - micSide - 8,
                y: (bounds.height - 36) / 2,
                width: 36,
                height: 36
            )
        }
        let midMinX = gifButton.frame.maxX + 4
        let midMaxX = micSide > 0 ? micButton.frame.minX - 8 : bounds.width
        let midWidth = max(0, midMaxX - midMinX)
        captionLabel.frame = CGRect(x: midMinX, y: 6, width: midWidth, height: 36)
        let slotWidth = max(24, midWidth / 3)
        for (index, button) in candidateButtons.enumerated() {
            button.frame = CGRect(
                x: midMinX + CGFloat(index) * slotWidth,
                y: 6,
                width: slotWidth,
                height: 36
            )
        }
        let hairline = 1 / max(traitCollection.displayScale, 1)
        for (index, separator) in separators.enumerated() {
            let x = midMinX + CGFloat(index + 1) * slotWidth - hairline / 2
            separator.frame = CGRect(x: x, y: 12, width: hairline, height: 24)
        }
    }

    private func applyColors() {
        gifButton.backgroundColor = gifTrayOpen
            ? KeyboardChromeTokens.coral.withAlphaComponent(0.35)
            : .clear
        gifButton.tintColor = KeyboardChromeTokens.glyphColor(dark: dark)
        gifButton.setTitleColor(KeyboardChromeTokens.glyphColor(dark: dark), for: .normal)
        captionLabel.textColor = KeyboardChromeTokens.glyphColor(dark: dark).withAlphaComponent(0.7)
        micButton.backgroundColor = KeyboardChromeTokens.coral
        micButton.tintColor = .white
        let separatorColor = KeyboardChromeTokens.quickTypeSeparator(dark: dark)
        separators.forEach { $0.backgroundColor = separatorColor }
        let leftWord = candidateWords.first ?? ""
        for (index, button) in candidateButtons.enumerated() {
            let word = index < candidateWords.count ? candidateWords[index] : ""
            let isCorrection = index == 1 && !word.isEmpty && word != leftWord
            button.backgroundColor = isCorrection
                ? KeyboardChromeTokens.candidateFill(dark: dark)
                : .clear
            button.setTitleColor(KeyboardChromeTokens.glyphColor(dark: dark), for: .normal)
        }
        gifButton.alpha = gifEnabled ? 1 : 0.45
    }

    private func refreshSlotVisibility() {
        let showCaption = !caption.isEmpty && !gifTrayOpen
        let showCandidates = !gifTrayOpen && !showCaption && candidateWords.contains { !$0.isEmpty }
        captionLabel.isHidden = !showCaption
        candidateButtons.forEach { $0.isHidden = !showCandidates }
        separators.forEach { $0.isHidden = !showCandidates }
    }

    @objc private func tapMic() { onMic?() }
    @objc private func tapGif() { onGif?() }
    @objc private func tapCandidate(_ sender: UIButton) { onCandidate?(sender.tag) }
}
