import SwiftUI

struct RoundedIconView: View {
    let systemImage: String
    let tint: Color

    var body: some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.15))
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .font(.system(size: 16, weight: .semibold))
        }
        .frame(width: 34, height: 34)
    }
}

struct TagBadge: View {
    let title: String
    let tint: Color

    var body: some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(tint)
            .background(
                Capsule()
                    .fill(tint.opacity(0.15))
            )
    }
}

struct SectionHeader: View {
    let title: String
    let subtitle: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.title3.weight(.semibold))
            if let subtitle {
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }
}

struct EmptyStateView: View {
    let title: String
    let message: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}

struct QuotaFooterView: View {
    let usageText: String
    let detailText: String
    /// `nil` cuando el backend no expone uso actual.
    /// En ese caso ocultamos la
    /// barra de progreso para no mentir visualmente.
    let progress: Double?
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(usageText)
                .font(.footnote.weight(.semibold))
            if let progress {
                ProgressView(value: progress)
                    .tint(tint)
            }
            Text(detailText)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }
}

struct FloatingActionButton: View {
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(Circle().fill(Color.accentColor))
                .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 6)
        }
        .accessibilityLabel("Create")
    }
}
