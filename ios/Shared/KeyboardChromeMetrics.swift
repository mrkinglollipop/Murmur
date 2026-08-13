import CoreGraphics

/// Width-bucket keyboard geometry. Pure so `MurmurKeyboardTests` can lock
/// heights without instantiating `KeyboardChromeView`.
struct KeyboardChromeMetrics: Equatable {
    enum Bucket: Equatable {
        case compact
        case regular
        case max

        static func from(width: CGFloat) -> Bucket {
            if width < 390 { return .compact }
            if width < 430 { return .regular }
            return .max
        }
    }

    let width: CGFloat
    let isLandscape: Bool
    let bucket: Bucket
    let keyboardHeight: CGFloat
    let accessoryHeight: CGFloat
    let sideInset: CGFloat
    let rowGap: CGFloat
    let keyGap: CGFloat
    let letterFont: CGFloat
    let specialFont: CGFloat
    let bottomInset: CGFloat
    let spaceUnits: CGFloat
    let spaceUnitsWithoutEmoji: CGFloat
    let modeUnits: CGFloat
    let returnUnits: CGFloat
    let emojiUnits: CGFloat
    let shiftUnits: CGFloat
    let asdfSpacerUnits: CGFloat
    /// Portrait letter-key cap from Apple Messages screenshots (Pro Max ~43pt).
    let letterKeyHeight: CGFloat
    /// Search-mode GIF strip above the keys. Extra input-view height is this plus a 4pt gap.
    let gifSearchPanelHeight: CGFloat

    static func metrics(width: CGFloat, isLandscape: Bool) -> KeyboardChromeMetrics {
        let bucket = Bucket.from(width: width)
        let keyboardHeight: CGFloat
        let accessoryHeight: CGFloat
        let sideInset: CGFloat
        let rowGap: CGFloat
        let keyGap: CGFloat
        let letterFont: CGFloat
        let specialFont: CGFloat
        let bottomInset: CGFloat
        let shiftUnits: CGFloat
        let asdfSpacerUnits: CGFloat
        let letterKeyHeight: CGFloat
        let gifSearchPanelHeight: CGFloat
        switch (bucket, isLandscape) {
        case (.compact, false):
            keyboardHeight = 232
            accessoryHeight = 40
            sideInset = 5
            rowGap = 8
            keyGap = 5
            letterFont = 22
            specialFont = 15
            bottomInset = 8
            shiftUnits = 1.5
            asdfSpacerUnits = 0.6
            letterKeyHeight = 40
            gifSearchPanelHeight = 140
        case (.regular, false):
            keyboardHeight = 248
            accessoryHeight = 42
            sideInset = 4
            rowGap = 10
            keyGap = 6
            letterFont = 24
            specialFont = 16
            bottomInset = 8
            shiftUnits = 1.65
            asdfSpacerUnits = 0.7
            letterKeyHeight = 42
            gifSearchPanelHeight = 148
        case (.max, false):
            // Apple Messages pane is ~339pt on Pro Max. ~80pt of that is the
            // system globe/mic well *outside* the input view. Pinning 340 put
            // that well in twice (422pt on device). 260 = accessory + 43pt keys.
            keyboardHeight = 260
            accessoryHeight = 44
            sideInset = 3
            rowGap = 12
            keyGap = 6
            letterFont = 25
            specialFont = 17
            bottomInset = 8
            shiftUnits = 1.75
            asdfSpacerUnits = 0.75
            letterKeyHeight = 43
            gifSearchPanelHeight = 160
        case (.compact, true):
            // Landscape heights are starting guesses; tests lock them so they cannot drift.
            keyboardHeight = 162
            accessoryHeight = 36
            sideInset = 6
            rowGap = 5
            keyGap = 5
            letterFont = 20
            specialFont = 14
            bottomInset = 4
            shiftUnits = 1.5
            asdfSpacerUnits = 0.6
            letterKeyHeight = 28
            gifSearchPanelHeight = 92
        case (.regular, true):
            keyboardHeight = 176
            accessoryHeight = 38
            sideInset = 5
            rowGap = 6
            keyGap = 5
            letterFont = 21
            specialFont = 15
            bottomInset = 5
            shiftUnits = 1.65
            asdfSpacerUnits = 0.7
            letterKeyHeight = 30
            gifSearchPanelHeight = 100
        case (.max, true):
            keyboardHeight = 188
            accessoryHeight = 40
            sideInset = 4
            rowGap = 7
            keyGap = 6
            letterFont = 22
            specialFont = 16
            bottomInset = 6
            shiftUnits = 1.75
            asdfSpacerUnits = 0.75
            letterKeyHeight = 32
            gifSearchPanelHeight = 108
        }
        return KeyboardChromeMetrics(
            width: width,
            isLandscape: isLandscape,
            bucket: bucket,
            keyboardHeight: keyboardHeight,
            accessoryHeight: accessoryHeight,
            sideInset: sideInset,
            rowGap: rowGap,
            keyGap: keyGap,
            letterFont: letterFont,
            specialFont: specialFont,
            bottomInset: bottomInset,
            spaceUnits: 5.0,
            spaceUnitsWithoutEmoji: 6.25,
            modeUnits: 1.5,
            returnUnits: 1.8,
            emojiUnits: 1.25,
            shiftUnits: shiftUnits,
            asdfSpacerUnits: asdfSpacerUnits,
            letterKeyHeight: letterKeyHeight,
            gifSearchPanelHeight: gifSearchPanelHeight
        )
    }
}
