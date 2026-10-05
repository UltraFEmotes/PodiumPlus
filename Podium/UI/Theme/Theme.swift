import SwiftUI

/// Shared spacing/corner-radius constants so screens don't accumulate
/// inconsistent magic numbers. Colors intentionally lean on system
/// materials/colors (`Color(.systemBackground)`, `.secondary`, the app's
/// `AccentColor` asset) rather than a custom palette, per the project's
/// "Apple-inspired, not Apple-copying" visual identity.
enum PodiumMetrics {
    static let screenPadding: CGFloat = 20
    static let sectionSpacing: CGFloat = 28
    static let cardCornerRadius: CGFloat = 16
    static let controlCornerRadius: CGFloat = 12
}

/// The shared card treatment — filled secondary background, hairline
/// border — so cards across screens match instead of each inlining its
/// own background + stroke.
struct PodiumCard: ViewModifier {
    var cornerRadius: CGFloat = PodiumMetrics.cardCornerRadius

    func body(content: Content) -> some View {
        content
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
            }
    }
}

extension View {
    func podiumCard(cornerRadius: CGFloat = PodiumMetrics.cardCornerRadius) -> some View {
        modifier(PodiumCard(cornerRadius: cornerRadius))
    }
}
