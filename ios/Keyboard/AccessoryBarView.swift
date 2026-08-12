import UIKit

/// Top accessory row: GIF (disabled until P2) · three candidate slots · Start.
final class AccessoryBarView: UIView {
    var onMic: (() -> Void)?
    var onGif: (() -> Void)?
    var onCandidate: ((Int) -> Void)?

    private let gifButton = UIButton(type: .system)
    private let candidateButtons: [UIButton] = (0..<3).map { _ in UIButton(type: .system) }
    private let captionLabel = UILabel()
    private let startButton = UIButton(type: .system)
    private var dark = true
    private var gifEnabled = false
    private var caption = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        gifButton.setTitle("GIF", for: .normal)
        gifButton.titleLabel?.font = .systemFont(ofSize: 12, weight: .bold)
        gifButton.addTarget(self, action: #selector(tapGif), for: .touchUpInside)
        gifButton.accessibilityLabel = "GIFs need Full Access and a Giphy key"
        gifButton.accessibilityIdentifier = "murmur.keyboard.gif"
        gifButton.isEnabled = false
        gifButton.layer.cornerRadius = KeyboardChromeTokens.chipCornerRadius
        addSubview(gifButton)

        for (index, button) in candidateButtons.enumerated() {
            button.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
            button.titleLabel?.adjustsFontSizeToFitWidth = true
            button.titleLabel?.minimumScaleFactor = 0.7
            button.layer.cornerRadius = KeyboardChromeTokens.chipCornerRadius
            button.tag = index
            button.addTarget(self, action: #selector(tapCandidate(_:)), for: .touchUpInside)
            button.accessibilityIdentifier = "murmur.keyboard.candidate.\(index)"
            addSubview(button)
        }

        captionLabel.font = .systemFont(ofSize: 12, weight: .medium)
        captionLabel.textAlignment = .center
        captionLabel.adjustsFontSizeToFitWidth = true
        captionLabel.numberOfLines = 2
        captionLabel.accessibilityIdentifier = "murmur.keyboard.caption"
        addSubview(captionLabel)

        var startConfiguration = UIButton.Configuration.plain()
        startConfiguration.title = "Start"
        startConfiguration.image = UIImage(systemName: "waveform")
        startConfiguration.imagePlacement = .trailing
        startConfiguration.imagePadding = 8
        startConfiguration.baseForegroundColor = .white
        startButton.configuration = startConfiguration
        startButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        startButton.layer.cornerRadius = 22
        startButton.addTarget(self, action: #selector(tapMic), for: .touchUpInside)
        startButton.accessibilityLabel = "Start dictation"
        startButton.accessibilityIdentifier = "murmur.keyboard.start"
        addSubview(startButton)

        applyColors()
    }

    required init?(coder: NSCoder) { nil }

    func setAppearance(dark: Bool) {
        self.dark = dark
        applyColors()
    }

    func setGifEnabled(_ enabled: Bool) {
        gifEnabled = enabled
        gifButton.isEnabled = enabled
        gifButton.alpha = enabled ? 1 : 0.45
        gifButton.accessibilityLabel = enabled
            ? "GIFs"
            : "GIFs need Full Access and a Giphy key"
    }

    func setCaption(_ text: String) {
        caption = text.trimmingCharacters(in: .whitespacesAndNewlines)
        captionLabel.text = caption
        let showCaption = !caption.isEmpty
        captionLabel.isHidden = !showCaption
        candidateButtons.forEach { $0.isHidden = showCaption }
        setNeedsLayout()
    }

    func setCandidates(_ words: [String]) {
        for (index, button) in candidateButtons.enumerated() {
            let word = index < words.count ? words[index] : ""
            button.setTitle(word, for: .normal)
            button.isEnabled = !word.isEmpty
            button.accessibilityLabel = word.isEmpty ? "Suggestion slot \(index + 1)" : word
        }
    }

    func setMicEnabled(_ enabled: Bool) {
        startButton.isEnabled = enabled
        startButton.alpha = enabled ? 1 : 0.4
    }

    func setMicHidden(_ hidden: Bool) {
        startButton.isHidden = hidden
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let gifSide: CGFloat = 40
        let startWidth: CGFloat = startButton.isHidden ? 0 : 106
        gifButton.frame = CGRect(x: 0, y: 4, width: gifSide, height: 40)
        if startWidth > 0 {
            startButton.frame = CGRect(x: bounds.width - startWidth, y: 2, width: startWidth, height: 44)
        }
        let midMinX = gifButton.frame.maxX + 6
        let midMaxX = startWidth > 0 ? startButton.frame.minX - 6 : bounds.width
        let midWidth = max(0, midMaxX - midMinX)
        captionLabel.frame = CGRect(x: midMinX, y: 6, width: midWidth, height: 36)
        let slotGap: CGFloat = 5
        let slotWidth = max(24, (midWidth - slotGap * 2) / 3)
        for (index, button) in candidateButtons.enumerated() {
            button.frame = CGRect(
                x: midMinX + CGFloat(index) * (slotWidth + slotGap),
                y: 6,
                width: slotWidth,
                height: 36
            )
        }
    }

    private func applyColors() {
        gifButton.backgroundColor = KeyboardChromeTokens.candidateFill(dark: dark)
        gifButton.tintColor = KeyboardChromeTokens.glyphColor(dark: dark)
        gifButton.setTitleColor(KeyboardChromeTokens.glyphColor(dark: dark), for: .normal)
        captionLabel.textColor = KeyboardChromeTokens.glyphColor(dark: dark).withAlphaComponent(0.7)
        startButton.backgroundColor = KeyboardChromeTokens.coral
        startButton.tintColor = .white
        startButton.setTitleColor(.white, for: .normal)
        for button in candidateButtons {
            button.backgroundColor = KeyboardChromeTokens.candidateFill(dark: dark)
            button.setTitleColor(KeyboardChromeTokens.glyphColor(dark: dark), for: .normal)
        }
        gifButton.alpha = gifEnabled ? 1 : 0.45
    }

    @objc private func tapMic() { onMic?() }
    @objc private func tapGif() { onGif?() }
    @objc private func tapCandidate(_ sender: UIButton) { onCandidate?(sender.tag) }
}
