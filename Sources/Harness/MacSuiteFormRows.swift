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
        SavyFormPicker(
            title: title,
            icon: icon,
            value: value,
            options: options,
            onSelect: onSelect
        )
    }

    static func valuePill(_ text: String) -> some View {
        Text(text)
            .font(Theme.savyRobotoMedium(9))
            .foregroundStyle(Color.black.opacity(0.72))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Theme.savyPaperAccent, in: RoundedRectangle(cornerRadius: 6))
    }

    static func scheduleRow(
        title: String,
        icon: String,
        detail: String,
        isOn: Binding<Bool>,
        date: Binding<Date>,
        components: DatePickerComponents
    ) -> some View {
        SavyScheduleDateRow(
            title: title,
            icon: icon,
            detail: detail,
            isOn: isOn,
            date: date,
            components: components
        )
    }

    static func toggleRow(
        title: String,
        icon: String,
        detail: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(spacing: 8) {
            intentIcon(icon)
            Text(title)
                .font(Theme.savyRobotoMedium(9))
                .foregroundStyle(Color.black)
            Spacer(minLength: 8)
            valuePill(detail)
                .opacity(isOn.wrappedValue ? 1 : 0.45)
            switchToggle(isOn: isOn)
        }
        .frame(minHeight: 28)
        .padding(.vertical, 3)
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

    /// Composer intent controls — full-width SAVY sections stacked under Delegate.
    static func composerIntentCard<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        intentCard(title, content: content)
    }
}

/// SAVY Schedule row — icon, label, gray pill value, crimson toggle on one line.
struct SavyScheduleDateRow: View {
    let title: String
    let icon: String
    let detail: String
    @Binding var isOn: Bool
    @Binding var date: Date
    let components: DatePickerComponents

    @State private var isPickerOpen = false

    var body: some View {
        HStack(spacing: 8) {
            MacSuiteFormRows.intentIcon(icon)
            Text(title)
                .font(Theme.savyRobotoMedium(9))
                .foregroundStyle(Color.black)
            Spacer(minLength: 8)
            Button {
                guard isOn else { return }
                isPickerOpen = true
            } label: {
                MacSuiteFormRows.valuePill(detail)
                    .opacity(isOn ? 1 : 0.45)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $isPickerOpen, arrowEdge: .bottom) {
                DatePicker("", selection: $date, displayedComponents: components)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .padding(12)
            }
            MacSuiteFormRows.switchToggle(isOn: $isOn)
        }
        .frame(minHeight: 28)
        .padding(.vertical, 3)
    }
}

/// SAVY Reminder picker surface — white popover, black labels, crimson value, checkmark on selection.
struct SavyFormPicker: View {
    let title: String
    let icon: String
    let value: String
    let options: [String]
    var emphasizedTitle = false
    let onSelect: (String) -> Void

    @State private var isOpen = false

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            MacSuiteFormRows.pickerLabel(
                title: title,
                icon: icon,
                value: value,
                emphasizedTitle: emphasizedTitle
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            SavyFormPickerPanel(selection: value, options: options) { option in
                onSelect(option)
                isOpen = false
            }
        }
    }
}

struct SavyFormPickerPanel: View {
    let selection: String
    let options: [String]
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(options, id: \.self) { option in
                Button {
                    onSelect(option)
                } label: {
                    HStack(spacing: 8) {
                        Group {
                            if option == selection {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(Color.black)
                            }
                        }
                        .frame(width: 14, alignment: .center)

                        Text(option)
                            .font(Theme.savyRobotoMedium(11))
                            .foregroundStyle(Color.black)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        option == selection ? Theme.savyPaperAccent : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.14), radius: 14, y: 6)
        .fixedSize(horizontal: true, vertical: true)
    }
}

private extension MacSuiteFormRows {
    static func pickerLabel(
        title: String,
        icon: String,
        value: String,
        emphasizedTitle: Bool = false
    ) -> some View {
        HStack(spacing: 6) {
            intentIcon(icon)
            Text(title)
                .font(Theme.savyRobotoMedium(9))
                .foregroundStyle(emphasizedTitle ? Theme.savyCrimson : Color.black)
            Spacer(minLength: 4)
            if !value.isEmpty {
                Text(value)
                    .font(Theme.savyRobotoMedium(9))
                    .foregroundStyle(Theme.savyCrimson)
                    .lineLimit(1)
            }
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 7, weight: .semibold))
                .foregroundStyle(Theme.savyCrimson)
        }
        .frame(minHeight: 28)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}
#endif