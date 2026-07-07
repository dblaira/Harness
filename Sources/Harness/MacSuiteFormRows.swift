#if os(macOS)
import SwiftUI

/// Shared SAVY entry-form row styling — icons crimson, labels black, values crimson.
enum MacSuiteFormRows {
    static var switchToggleStyle: SwitchToggleStyle {
        SwitchToggleStyle(tint: Theme.savyCrimson)
    }

    static func switchToggle(isOn: Binding<Bool>) -> some View {
        Toggle("", isOn: isOn)
            .labelsHidden()
            .toggleStyle(switchToggleStyle)
            .controlSize(.mini)
    }
    static func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(Theme.savyRobotoMedium(8))
            .foregroundStyle(Color.black.opacity(0.48))
            .padding(.leading, 6)
    }

    static func intentIcon(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.savyCrimson)
            .frame(width: 17)
    }

    static func divider() -> some View {
        Rectangle()
            .fill(Color.black.opacity(0.08))
            .frame(height: 1)
            .padding(.leading, 22)
    }

    static func menuRow(
        title: String,
        icon: String,
        value: String,
        options: [String],
        onSelect: @escaping (String) -> Void
    ) -> some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button(option) { onSelect(option) }
            }
        } label: {
            HStack(spacing: 6) {
                intentIcon(icon)
                Text(title)
                    .font(Theme.savyRobotoMedium(9))
                    .foregroundStyle(Color.black)
                Spacer(minLength: 4)
                Text(value)
                    .font(Theme.savyRobotoMedium(9))
                    .foregroundStyle(Theme.savyCrimson)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(Theme.savyCrimson)
            }
            .frame(minHeight: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .tint(Theme.savyCrimson)
    }

    static func toggleRow(
        title: String,
        icon: String,
        detail: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(spacing: 6) {
            intentIcon(icon)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(Theme.savyRobotoMedium(9))
                    .foregroundStyle(Color.black)
                Text(detail)
                    .font(Theme.savyRobotoMedium(8))
                    .foregroundStyle(Theme.savyTertiaryText)
            }
            Spacer(minLength: 4)
            switchToggle(isOn: isOn)
        }
        .frame(minHeight: 19)
    }

    static func intentCard<Content: View>(
        _ title: String,
        width: CGFloat? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionLabel(title)
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(.vertical, 1)
            .padding(.horizontal, 6)
            .frame(maxWidth: width == nil ? .infinity : width, alignment: .leading)
            .background(Theme.savyCard, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.black.opacity(0.08), lineWidth: 1)
            )
        }
        .frame(width: width, alignment: .leading)
    }

    /// Composer intent controls — fixed width so rows do not stretch across the chat column.
    static let composerIntentCardWidth: CGFloat = 168

    static func composerIntentCard<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        intentCard(title, width: composerIntentCardWidth, content: content)
    }
}
#endif