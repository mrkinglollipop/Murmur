import UIKit

/// Apple-like emoji pane: search, 9-column grid, category strip. No Genmoji.
final class EmojiPickerView: UIView, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    var onSelect: ((String) -> Void)?
    var onABC: (() -> Void)?
    var onDelete: (() -> Void)?
    var onSearchModeChange: (() -> Void)?

    private(set) var isSearchMode = false
    private(set) var searchText = ""

    private let searchContainer = UIView()
    private let searchIcon = UIImageView()
    private let searchLabel = UILabel()
    private let clearButton = UIButton(type: .system)
    private let collection: UICollectionView
    private let emptyLabel = UILabel()
    private let categoryBar = UIView()
    private let abcButton = UIButton(type: .system)
    private let deleteButton = UIButton(type: .system)
    private var tabButtons: [UIButton] = []

    private enum Tab: Int, CaseIterable {
        case recents
        case smileys
        case animals
        case food
        case activity
        case travel
        case objects
        case symbols
        case flags

        var symbol: String {
            switch self {
            case .recents: return "clock"
            case .smileys: return "face.smiling"
            case .animals: return "hare"
            case .food: return "fork.knife"
            case .activity: return "soccerball"
            case .travel: return "car"
            case .objects: return "lightbulb"
            case .symbols: return "heart"
            case .flags: return "flag"
            }
        }

        var catalog: EmojiCatalog.Category? {
            switch self {
            case .recents: return nil
            case .smileys: return .smileys
            case .animals: return .animals
            case .food: return .food
            case .activity: return .activity
            case .travel: return .travel
            case .objects: return .objects
            case .symbols: return .symbols
            case .flags: return .flags
            }
        }

        var accessibilityName: String {
            switch self {
            case .recents: return "Recents"
            case .smileys: return "Smileys and people"
            case .animals: return "Animals and nature"
            case .food: return "Food and drink"
            case .activity: return "Activity"
            case .travel: return "Travel and places"
            case .objects: return "Objects"
            case .symbols: return "Symbols"
            case .flags: return "Flags"
            }
        }
    }

    private var tab: Tab = .recents
    private var glyphs: [String] = []
    private var dark = true
    private var deleteRepeatTask: Task<Void, Never>?
    private let columns = 9

    override init(frame: CGRect) {
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 0
        layout.minimumLineSpacing = 2
        layout.sectionInset = .zero
        collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: frame)
        configure()
        reloadGlyphs()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        deleteRepeatTask?.cancel()
    }

    func setAppearance(dark: Bool) {
        self.dark = dark
        applyColors()
        reloadTabTint()
    }

    func resetMode() {
        isSearchMode = false
        searchText = ""
        tab = .recents
        refreshSearchLabel()
        reloadGlyphs()
        onSearchModeChange?()
    }

    func insertSearchText(_ text: String) {
        enterSearchMode()
        if text == "\n" { return }
        searchText += text
        refreshSearchLabel()
        reloadGlyphs()
    }

    func deleteSearchText() -> Bool {
        guard isSearchMode, !searchText.isEmpty else { return false }
        searchText.removeLast()
        refreshSearchLabel()
        reloadGlyphs()
        return true
    }

    /// Search bar + two emoji rows + category bar. Chrome keeps letter keys in the remaining height.
    func searchPanelHeight(forWidth width: CGFloat) -> CGFloat {
        let inner = max(1, width - 24)
        let cell = floor(inner / CGFloat(columns))
        let bar: CGFloat = EmojiSearchRouting.showsCategoryBar(isSearchMode: true) ? 44 : 0
        return 8 + 36 + 6 + cell * 2 + 2 + 6 + bar
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side: CGFloat = 12
        searchContainer.frame = CGRect(x: side, y: 8, width: bounds.width - side * 2, height: 36)
        searchIcon.frame = CGRect(x: 10, y: 9, width: 18, height: 18)
        let clearWidth: CGFloat = searchText.isEmpty ? 0 : 32
        clearButton.frame = CGRect(
            x: searchContainer.bounds.width - 6 - clearWidth,
            y: 2,
            width: clearWidth,
            height: 32
        )
        searchLabel.frame = CGRect(
            x: 34,
            y: 0,
            width: searchContainer.bounds.width - 40 - clearWidth,
            height: 36
        )
        let showBar = EmojiSearchRouting.showsCategoryBar(isSearchMode: isSearchMode)
        let preferredBarHeight: CGFloat = showBar ? 44 : 0
        let searchBottom = searchContainer.frame.maxY
        var barHeight = preferredBarHeight
        var barY = bounds.height - barHeight
        if showBar, barY < searchBottom {
            barY = searchBottom
            barHeight = max(0, bounds.height - barY)
        }
        categoryBar.frame = CGRect(
            x: 0,
            y: barY,
            width: bounds.width,
            height: barHeight
        )
        categoryBar.isHidden = !showBar
        abcButton.frame = CGRect(x: 4, y: 4, width: 48, height: 36)
        deleteButton.frame = CGRect(x: bounds.width - 52, y: 4, width: 48, height: 36)
        let iconArea = CGRect(
            x: abcButton.frame.maxX,
            y: 4,
            width: deleteButton.frame.minX - abcButton.frame.maxX,
            height: 36
        )
        let tabCount = CGFloat(tabButtons.count)
        let slot = iconArea.width / max(tabCount, 1)
        for (index, button) in tabButtons.enumerated() {
            let size: CGFloat = 32
            button.frame = CGRect(
                x: iconArea.minX + CGFloat(index) * slot + (slot - size) / 2,
                y: iconArea.minY + (iconArea.height - size) / 2,
                width: size,
                height: size
            )
            button.layer.cornerRadius = size / 2
        }
        let collectionTop = searchContainer.frame.maxY + 6
        collection.frame = CGRect(
            x: side,
            y: collectionTop,
            width: bounds.width - side * 2,
            height: max(0, categoryBar.frame.minY - 4 - collectionTop)
        )
        emptyLabel.frame = collection.frame.insetBy(dx: 12, dy: 16)
        collection.collectionViewLayout.invalidateLayout()
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        glyphs.count
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: EmojiCell.reuseID,
            for: indexPath
        )
        if let cell = cell as? EmojiCell, indexPath.item < glyphs.count {
            cell.configure(glyphs[indexPath.item], at: indexPath.item)
        }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard indexPath.item < glyphs.count else { return }
        let glyph = glyphs[indexPath.item]
        AppGroupStore.rememberEmoji(glyph)
        onSelect?(glyph)
        if tab == .recents, !isSearchMode || searchText.isEmpty {
            reloadGlyphs(keepOffset: false)
        }
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        let width = max(28, floor(collectionView.bounds.width / CGFloat(columns)))
        return CGSize(width: width, height: width)
    }

    private func configure() {
        searchContainer.layer.cornerRadius = 18
        searchContainer.layer.cornerCurve = .continuous
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapSearch))
        searchContainer.addGestureRecognizer(tap)
        searchContainer.accessibilityIdentifier = "murmur.keyboard.emoji.search"
        addSubview(searchContainer)

        let mag = UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        searchIcon.image = UIImage(systemName: "magnifyingglass", withConfiguration: mag)
        searchIcon.contentMode = .scaleAspectFit
        searchContainer.addSubview(searchIcon)

        searchLabel.font = .systemFont(ofSize: 16, weight: .regular)
        searchLabel.isUserInteractionEnabled = false
        searchContainer.addSubview(searchLabel)

        clearButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        clearButton.addTarget(self, action: #selector(tapClear), for: .touchUpInside)
        clearButton.accessibilityLabel = "Clear emoji search"
        clearButton.accessibilityIdentifier = "murmur.keyboard.emoji.search.clear"
        searchContainer.addSubview(clearButton)

        collection.backgroundColor = .clear
        collection.dataSource = self
        collection.delegate = self
        collection.alwaysBounceVertical = true
        collection.keyboardDismissMode = .none
        collection.register(EmojiCell.self, forCellWithReuseIdentifier: EmojiCell.reuseID)
        collection.accessibilityIdentifier = "murmur.keyboard.emoji.grid"
        addSubview(collection)

        emptyLabel.font = .systemFont(ofSize: 15, weight: .medium)
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 2
        emptyLabel.isUserInteractionEnabled = false
        addSubview(emptyLabel)

        addSubview(categoryBar)
        abcButton.setTitle("ABC", for: .normal)
        abcButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        abcButton.addTarget(self, action: #selector(tapABC), for: .touchUpInside)
        abcButton.accessibilityLabel = "Letters"
        abcButton.accessibilityIdentifier = "murmur.keyboard.emoji.abc"
        categoryBar.addSubview(abcButton)

        let delConfig = UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        deleteButton.setImage(UIImage(systemName: "delete.backward", withConfiguration: delConfig), for: .normal)
        deleteButton.addTarget(self, action: #selector(deleteTouchDown), for: .touchDown)
        deleteButton.addTarget(
            self,
            action: #selector(deleteTouchEnd),
            for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit]
        )
        deleteButton.accessibilityLabel = "Delete"
        deleteButton.accessibilityIdentifier = "murmur.keyboard.emoji.delete"
        categoryBar.addSubview(deleteButton)

        let iconConfig = UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        tabButtons = Tab.allCases.map { item in
            let button = UIButton(type: .system)
            button.setImage(UIImage(systemName: item.symbol, withConfiguration: iconConfig), for: .normal)
            button.tag = item.rawValue
            button.accessibilityLabel = item.accessibilityName
            button.accessibilityIdentifier = "murmur.keyboard.emoji.tab.\(item.rawValue)"
            button.addTarget(self, action: #selector(tapTab(_:)), for: .touchUpInside)
            categoryBar.addSubview(button)
            return button
        }

        refreshSearchLabel()
        applyColors()
        reloadTabTint()
    }

    private func enterSearchMode() {
        guard !isSearchMode else { return }
        isSearchMode = true
        onSearchModeChange?()
        setNeedsLayout()
    }

    private func applyColors() {
        let glyph = KeyboardChromeTokens.glyphColor(dark: dark)
        backgroundColor = .clear
        searchContainer.backgroundColor = dark
            ? UIColor(white: 0.22, alpha: 0.95)
            : UIColor(white: 1, alpha: 0.92)
        searchIcon.tintColor = glyph.withAlphaComponent(0.45)
        searchLabel.textColor = glyph
        clearButton.tintColor = glyph.withAlphaComponent(0.45)
        emptyLabel.textColor = glyph.withAlphaComponent(0.55)
        abcButton.tintColor = glyph
        abcButton.setTitleColor(glyph, for: .normal)
        deleteButton.tintColor = glyph
    }

    private func refreshSearchLabel() {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            searchLabel.text = "Search Emoji"
            searchLabel.alpha = 0.45
            clearButton.isHidden = true
        } else {
            searchLabel.text = searchText
            searchLabel.alpha = 1
            clearButton.isHidden = false
        }
        searchContainer.accessibilityLabel = trimmed.isEmpty ? "Search Emoji" : "Emoji search \(searchText)"
        setNeedsLayout()
    }

    private func reloadGlyphs(keepOffset: Bool = true) {
        let offset = collection.contentOffset
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if isSearchMode, !trimmed.isEmpty {
            glyphs = EmojiCatalog.search(query: trimmed).map(\.glyph)
        } else if let category = tab.catalog {
            glyphs = EmojiCatalog.items(in: category).map(\.glyph)
        } else {
            let stored = AppGroupStore.recentEmoji
            glyphs = stored.isEmpty ? EmojiCatalog.fallbackRecents : stored
        }
        emptyLabel.text = glyphs.isEmpty ? "No matching emoji" : nil
        emptyLabel.isHidden = !glyphs.isEmpty
        collection.reloadData()
        if keepOffset, collection.contentSize.height > collection.bounds.height {
            collection.setContentOffset(offset, animated: false)
        } else {
            collection.setContentOffset(.zero, animated: false)
        }
        reloadTabTint()
    }

    private func reloadTabTint() {
        let glyph = KeyboardChromeTokens.glyphColor(dark: dark)
        let selectedFill = dark ? UIColor(white: 1, alpha: 0.16) : UIColor(white: 0, alpha: 0.10)
        for button in tabButtons {
            let selected = Tab(rawValue: button.tag) == tab && !isSearchMode
            button.tintColor = selected ? glyph : glyph.withAlphaComponent(0.45)
            button.backgroundColor = selected ? selectedFill : .clear
        }
    }

    @objc private func tapSearch() {
        enterSearchMode()
    }

    @objc private func tapClear() {
        searchText = ""
        refreshSearchLabel()
        reloadGlyphs(keepOffset: false)
    }

    @objc private func tapABC() {
        onABC?()
    }

    @objc private func tapTab(_ sender: UIButton) {
        guard let next = Tab(rawValue: sender.tag) else { return }
        tab = next
        if isSearchMode {
            searchText = ""
            isSearchMode = false
            refreshSearchLabel()
            reloadGlyphs(keepOffset: false)
            onSearchModeChange?()
            return
        }
        reloadGlyphs(keepOffset: false)
    }

    @objc private func deleteTouchDown() {
        onDelete?()
        deleteRepeatTask?.cancel()
        deleteRepeatTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            while !Task.isCancelled {
                await MainActor.run { self?.onDelete?() }
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
    }

    @objc private func deleteTouchEnd() {
        deleteRepeatTask?.cancel()
        deleteRepeatTask = nil
    }
}

private final class EmojiCell: UICollectionViewCell {
    static let reuseID = "murmur.emoji.cell"
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.6
        contentView.addSubview(label)
        isAccessibilityElement = true
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = contentView.bounds
        label.font = .systemFont(ofSize: min(32, bounds.height * 0.78))
    }

    func configure(_ glyph: String, at index: Int) {
        label.text = glyph
        accessibilityLabel = glyph
        accessibilityIdentifier = "murmur.keyboard.emoji.cell.\(index)"
    }
}
