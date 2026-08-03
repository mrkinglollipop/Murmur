import SwiftUI

/// Reusable search field: magnifier, clear button, optional result count,
/// Cmd-F focus shortcut, and Esc-to-clear-and-blur.
struct SearchBar: View {
    @Binding var text: String
    var placeholder: String
    var resultCount: Int?
    var isFocused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(Theme.textSecondary)
                .font(.system(size: 12))

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(Theme.body(13))
                .focused(isFocused)
                .onKeyPress(.escape) {
                    if !text.isEmpty {
                        text = ""
                        return .handled
                    }
                    isFocused.wrappedValue = false
                    return .handled
                }

            if !text.isEmpty {
                Button {
                    text = ""
                    isFocused.wrappedValue = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
                .accessibilityLabel("Clear search")

                if let resultCount {
                    Text("\(resultCount) result\(resultCount == 1 ? "" : "s")")
                        .font(Theme.body(11))
                        .foregroundColor(Theme.textSecondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .murmurGlassCard()
        .background {
            Button("") { isFocused.wrappedValue = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
        }
    }
}
