import UIKit

/// GIF tray: search + 3-column stills + Giphy attribution. Keys type into search.
final class GiphyTrayView: UIView, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    var onSelect: ((GiphyClient.GIF) -> Void)?
    var onModeChange: (() -> Void)?

    private(set) var isSearchMode = false
    private(set) var searchText = ""

    var apiKey = ""

    private let searchContainer = UIView()
    private let searchLabel = UILabel()
    private let clearButton = UIButton(type: .system)
    private let collection: UICollectionView
    private let attribution = UILabel()
    private let statusLabel = UILabel()
    private let retryButton = UIButton(type: .system)

    private var items: [GiphyClient.GIF] = []
    private var loadTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var loadGeneration = 0
    private var lastError: String?
    private var isLoading = false
    private let imageCache = NSCache<NSURL, UIImage>()
    private var dark = true

    override init(frame: CGRect) {
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 6
        layout.minimumLineSpacing = 6
        layout.sectionInset = .zero
        collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: frame)
        imageCache.countLimit = 48
        imageCache.totalCostLimit = 8 * 1024 * 1024
        configure()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        loadTask?.cancel()
        debounceTask?.cancel()
    }

    func setAppearance(dark: Bool) {
        self.dark = dark
        applyColors()
    }

    func appear() {
        if items.isEmpty {
            load(query: searchText)
        }
    }

    func resetMode() {
        isSearchMode = false
        debounceTask?.cancel()
        onModeChange?()
    }

    func enterSearchMode() {
        guard !isSearchMode else { return }
        isSearchMode = true
        onModeChange?()
    }

    func insertSearchText(_ text: String) {
        enterSearchMode()
        if text == "\n" {
            submitSearch()
            return
        }
        searchText += text
        refreshSearchLabel()
        scheduleSearch()
    }

    func deleteSearchText() {
        guard !searchText.isEmpty else { return }
        enterSearchMode()
        searchText.removeLast()
        refreshSearchLabel()
        scheduleSearch()
    }

    func submitSearch() {
        debounceTask?.cancel()
        load(query: searchText)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let searchHeight: CGFloat = 36
        searchContainer.frame = CGRect(x: 0, y: 0, width: bounds.width, height: searchHeight)
        clearButton.frame = CGRect(x: bounds.width - 36, y: 2, width: 32, height: 32)
        searchLabel.frame = CGRect(x: 12, y: 0, width: bounds.width - 48, height: searchHeight)
        let attributionHeight: CGFloat = isSearchMode ? 0 : 18
        attribution.frame = CGRect(
            x: 0,
            y: bounds.height - attributionHeight,
            width: bounds.width,
            height: attributionHeight
        )
        attribution.isHidden = isSearchMode
        collection.isHidden = false
        let collectionTop = searchContainer.frame.maxY + 6
        collection.frame = CGRect(
            x: 0,
            y: collectionTop,
            width: bounds.width,
            height: max(0, attribution.frame.minY - 4 - collectionTop)
        )
        collection.collectionViewLayout.invalidateLayout()
        statusLabel.frame = collection.frame.insetBy(dx: 12, dy: 24)
        retryButton.frame = CGRect(
            x: (bounds.width - 88) / 2,
            y: statusLabel.frame.midY + 18,
            width: 88,
            height: 32
        )
        let showStatus = isLoading || lastError != nil || items.isEmpty
        statusLabel.isHidden = !showStatus
        retryButton.isHidden = lastError == nil
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: GiphyCell.reuseID, for: indexPath)
        if let cell = cell as? GiphyCell, indexPath.item < items.count {
            let gif = items[indexPath.item]
            cell.configure(title: gif.title)
            cell.loadTask?.cancel()
            if let cached = imageCache.object(forKey: gif.previewURL as NSURL) {
                cell.setImage(cached)
            } else {
                cell.setImage(nil)
                cell.loadTask = Task { [weak self, weak cell] in
                    guard let self else { return }
                    do {
                        let data = try await GiphyClient.fetchData(from: gif.previewURL)
                        guard !Task.isCancelled, let image = UIImage(data: data) else { return }
                        self.imageCache.setObject(
                            image,
                            forKey: gif.previewURL as NSURL,
                            cost: data.count
                        )
                        await MainActor.run {
                            cell?.setImage(image)
                        }
                    } catch {
                        return
                    }
                }
            }
        }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard indexPath.item < items.count else { return }
        onSelect?(items[indexPath.item])
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        let spacing: CGFloat = 6
        let columns: CGFloat = 3
        let width = floor((collectionView.bounds.width - spacing * (columns - 1)) / columns)
        let natural = max(52, width * 0.82)
        let height: CGFloat
        if isSearchMode, collectionView.bounds.height > 1 {
            height = min(natural, collectionView.bounds.height)
        } else {
            height = natural
        }
        return CGSize(width: max(44, width), height: height)
    }

    private func configure() {
        searchContainer.layer.cornerRadius = 10
        searchContainer.layer.cornerCurve = .continuous
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapSearch(_:)))
        tap.cancelsTouchesInView = false
        searchContainer.addGestureRecognizer(tap)
        searchContainer.accessibilityIdentifier = "murmur.keyboard.giphy.search"
        addSubview(searchContainer)

        searchLabel.font = .systemFont(ofSize: 15, weight: .regular)
        searchLabel.isUserInteractionEnabled = false
        searchContainer.addSubview(searchLabel)

        clearButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        clearButton.addTarget(self, action: #selector(tapClear), for: .touchUpInside)
        clearButton.accessibilityLabel = "Clear GIF search"
        clearButton.accessibilityIdentifier = "murmur.keyboard.giphy.clear"
        searchContainer.addSubview(clearButton)

        collection.backgroundColor = .clear
        collection.clipsToBounds = true
        clipsToBounds = true
        collection.dataSource = self
        collection.delegate = self
        collection.alwaysBounceVertical = true
        collection.bounces = true
        collection.isScrollEnabled = true
        collection.delaysContentTouches = true
        collection.canCancelContentTouches = true
        collection.register(GiphyCell.self, forCellWithReuseIdentifier: GiphyCell.reuseID)
        collection.accessibilityIdentifier = "murmur.keyboard.giphy.grid"
        addSubview(collection)

        attribution.font = .systemFont(ofSize: 11, weight: .semibold)
        attribution.textAlignment = .center
        attribution.text = "Powered By GIPHY"
        attribution.accessibilityIdentifier = "murmur.keyboard.giphy.attribution"
        addSubview(attribution)

        statusLabel.font = .systemFont(ofSize: 14, weight: .medium)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 3
        statusLabel.accessibilityIdentifier = "murmur.keyboard.giphy.status"
        addSubview(statusLabel)

        retryButton.setTitle("Retry", for: .normal)
        retryButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        retryButton.addTarget(self, action: #selector(tapRetry), for: .touchUpInside)
        retryButton.accessibilityIdentifier = "murmur.keyboard.giphy.retry"
        addSubview(retryButton)

        refreshSearchLabel()
        applyColors()
    }

    private func applyColors() {
        let glyph = KeyboardChromeTokens.glyphColor(dark: dark)
        searchContainer.backgroundColor = KeyboardChromeTokens.candidateFill(dark: dark)
        searchLabel.textColor = glyph
        clearButton.tintColor = glyph.withAlphaComponent(0.55)
        attribution.textColor = glyph.withAlphaComponent(0.55)
        statusLabel.textColor = glyph.withAlphaComponent(0.7)
        retryButton.tintColor = KeyboardChromeTokens.coral
    }

    private func refreshSearchLabel() {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            searchLabel.text = "Search GIPHY"
            searchLabel.alpha = 0.45
            clearButton.isHidden = true
        } else {
            searchLabel.text = searchText
            searchLabel.alpha = 1
            clearButton.isHidden = false
        }
        searchContainer.accessibilityLabel = trimmed.isEmpty ? "Search GIPHY" : "GIF search \(searchText)"
    }

    private func scheduleSearch() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.submitSearch()
            }
        }
    }

    private func load(query: String) {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            lastError = "Add a Giphy key in Murmur."
            items = []
            isLoading = false
            statusLabel.text = lastError
            collection.reloadData()
            setNeedsLayout()
            return
        }
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = trimmedQuery.isEmpty
            ? GiphyClient.trendingURL(apiKey: trimmedKey)
            : GiphyClient.searchURL(apiKey: trimmedKey, query: trimmedQuery)
        guard let url else {
            lastError = "Couldn’t load GIFs."
            statusLabel.text = lastError
            setNeedsLayout()
            return
        }
        loadGeneration += 1
        let generation = loadGeneration
        loadTask?.cancel()
        isLoading = true
        lastError = nil
        statusLabel.text = "Loading…"
        retryButton.isHidden = true
        setNeedsLayout()
        loadTask = Task { [weak self] in
            do {
                let gifs = try await GiphyClient.fetch(url: url)
                await MainActor.run {
                    guard let self, generation == self.loadGeneration else { return }
                    self.isLoading = false
                    self.items = gifs
                    if gifs.isEmpty {
                        self.lastError = nil
                        self.statusLabel.text = trimmedQuery.isEmpty
                            ? "No GIFs right now."
                            : "No GIFs for that."
                    } else {
                        self.statusLabel.text = nil
                    }
                    self.collection.reloadData()
                    self.setNeedsLayout()
                }
            } catch {
                await MainActor.run {
                    guard let self, generation == self.loadGeneration else { return }
                    self.isLoading = false
                    self.items = []
                    self.lastError = Self.message(for: error)
                    self.statusLabel.text = self.lastError
                    self.collection.reloadData()
                    self.setNeedsLayout()
                }
            }
        }
    }

    private static func message(for error: Error) -> String {
        if let client = error as? GiphyClient.ClientError {
            switch client {
            case .missingKey:
                return "Add a Giphy key in Murmur."
            case .http(let code) where code == 401 || code == 403:
                return "Giphy key was rejected."
            case .http, .badURL, .decode:
                return "Couldn’t load GIFs."
            }
        }
        return "Couldn’t load GIFs."
    }

    @objc private func tapSearch(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: searchContainer)
        if !clearButton.isHidden, clearButton.frame.contains(point) { return }
        enterSearchMode()
    }

    @objc private func tapClear() {
        searchText = ""
        refreshSearchLabel()
        isSearchMode = false
        onModeChange?()
        load(query: "")
    }

    @objc private func tapRetry() {
        load(query: searchText)
    }
}

private final class GiphyCell: UICollectionViewCell {
    static let reuseID = "giphy.cell"
    var loadTask: Task<Void, Never>?
    private let imageView = UIImageView()
    private let placeholder = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.layer.cornerRadius = 10
        contentView.layer.cornerCurve = .continuous
        contentView.clipsToBounds = true
        placeholder.backgroundColor = UIColor.secondarySystemFill
        contentView.addSubview(placeholder)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        contentView.addSubview(imageView)
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        placeholder.frame = contentView.bounds
        imageView.frame = contentView.bounds
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel()
        loadTask = nil
        imageView.image = nil
        imageView.isHidden = true
    }

    func configure(title: String) {
        accessibilityLabel = title.isEmpty ? "GIF" : title
    }

    func setImage(_ image: UIImage?) {
        imageView.image = image
        imageView.isHidden = image == nil
    }
}
