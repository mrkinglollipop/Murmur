import SwiftUI

/// Reusable destructive-delete confirmation dialog for list/detail views.
struct ConfirmDeleteModifier: ViewModifier {
    @Binding var isPresented: Bool
    let title: String
    let message: String
    let onConfirm: () -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
            title,
            isPresented: $isPresented,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive, action: onConfirm)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(message)
        }
    }
}

extension View {
    /// Presents a standard destructive delete confirmation when `isPresented`
    /// is true.
    func confirmDelete(
        isPresented: Binding<Bool>,
        title: String,
        message: String = "This can't be undone.",
        onConfirm: @escaping () -> Void
    ) -> some View {
        modifier(ConfirmDeleteModifier(
            isPresented: isPresented,
            title: title,
            message: message,
            onConfirm: onConfirm
        ))
    }
}
