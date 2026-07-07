#if os(macOS)
import SwiftUI

/// Shared SAVY entry-form row styling — mirrors SAVY-iOS `ReminderFormView`:
/// cream card rows, Roboto labels, crimson values, compact switches, working menu pickers.
enum MacSuiteFormRows {
    /// iOS Form switches sit ~16pt tall inside ~44pt rows; scale macOS switches to match 9pt rows.
    private static let toggleScale: CGFloat = 0.52
    private static let toggleSlotWidth: CGFloat = 28
    private static let toggleSlotHeight: CGFloat = 14

    static func switchToggle(isOn: Binding<Bool>) -> some View {
        Toggle("", isOn: isOn)
            .labelsHidden()
            .toggleStyle(SwitchToggleStyle(tint: Theme.savyCrimson))
            .controlSize(.mini)
            .scaleEffect(toggleScale)
            .frame(width: toggleSlotWidth, height: toggleSlotHeight)
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
        selection: Binding<String>,
        options: [String]
    ) -> some View {
        SavyMenuRow(title: title, icon: icon, selection: selection, options: options)
    }

    /// Schedule rows follow SAVY: label + compact toggle on one line, date/time field below when on.
    static func scheduleRow(
        title: String,
        icon: String,
        detail: String,
        isOn: Binding<Bool>,
        date: Binding<Date>,
        components: DatePickerComponents
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                intentIcon(icon)
                Text(title)
                    .font(Theme.savyRobotoMedium(9))
                    .foregroundStyle(Color.black)
                Spacer(minLength: 0)
                switchToggle(isOn: isOn)
            }
            .frame(minHeight: 16)

            if isOn.wrappedValue {
                HStack(spacing: 0) {
                    Spacer().frame(width: 23)
                    DatePicker("", selection: date, displayedComponents: components)
                        .labelsHidden()
                        .datePickerStyle(.field)
                        .font(Theme.savyRobotoMedium(8))
                        .tint(Theme.savyCrimson)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                HStack(spacing: 0) {
                    Spacer().frame(width: 23)
                    Text(detail)
                        .font(Theme.savyRobotoMedium(8))
                        .foregroundStyle(Theme.savyTertiaryText)
                }
            }
        }
        .padding(.vertical, 1)
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
            Spacer(minLength: 0)
            switchToggle(isOn: isOn)
        }
        .frame(minHeight: 16)
        .padding(.vertical, 1)
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

/// Menu-backed picker — reliable on macOS (SwiftUI `Picker(.menu)` ignores custom row labels).
private struct SavyMenuRow: View {
    let title: String
    let icon: String
    @Binding var selection: String
    let options: [String]

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button {
                    selection = option
                } label: {
                    HStack {
                        Text(option)
                            .font(Theme.savyRobotoMedium(9))
                        Spacer()
                        if option == selection {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                MacSuiteFormRows.intentIcon(icon)
                Text(title)
                    .font(Theme.savyRobotoMedium(9))
                    .foregroundStyle(Color.black)
                Spacer(minLength: 0)
                Text(selection)
                    .font(Theme.savyRobotoMedium(9))
                    .foregroundStyle(Theme.savyCrimson)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(Theme.savyCrimson)
            }
            .frame(minHeight: 16)
            .padding(.vertical, 1)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
