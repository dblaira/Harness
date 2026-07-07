#if os(macOS)
import SwiftUI
import OntologyKit

/// Cockpit section listing both routine sources: Hermes cron jobs mirrored
/// read-only from ~/.hermes/cron/jobs.json (their last_status verbatim — a
/// failing job showing its failure is a feature), and native Harness
/// routines that fire headless ledger runs (pause / resume / run-now /
/// delete, plus a small add form).
struct RoutinesView: View {
    @EnvironmentObject private var scheduler: RoutineScheduler

    @State private var newName = ""
    @State private var newPrompt = ""
    @State private var newKind: RoutineSchedule.Kind = .interval
    @State private var newMinutes = 60
    @State private var newRunAt = Date().addingTimeInterval(3600)
    @State private var showingAddForm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader

            VStack(alignment: .leading, spacing: 14) {
                hermesSection
                harnessSection
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.macEntry.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.macHair, lineWidth: 1))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Header

    private var sectionHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.2.circlepath")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.macRed.opacity(0.9))
                .frame(width: 16)
            Text("Routines")
                .font(.system(size: 13).weight(.bold))
                .foregroundStyle(Theme.macInk.opacity(0.78))
            Spacer()
            Button {
                showingAddForm.toggle()
            } label: {
                Label(showingAddForm ? "Close" : "New Routine", systemImage: showingAddForm ? "xmark.circle" : "plus.circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.macInk.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help("Create a native Harness routine")
        }
    }

    // MARK: Hermes (read-only)

    private var hermesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                subheading("Hermes cron")
                badge("read-only", icon: "eye")
                Spacer()
                Button {
                    scheduler.refreshHermesJobs()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.macInk.opacity(0.55))
                }
                .buttonStyle(.plain)
                .help("Re-read ~/.hermes/cron/jobs.json")
            }

            if let readError = scheduler.hermesReadError {
                statusLine("Could not read ~/.hermes/cron/jobs.json: \(readError)", failed: true)
            } else if scheduler.hermesJobs.isEmpty {
                emptyLine("No Hermes cron jobs found.")
            } else {
                ForEach(scheduler.hermesJobs) { job in
                    hermesRow(job)
                }
            }
        }
    }

    private func hermesRow(_ job: HermesCronJob) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(job.name)
                    .font(.system(size: 12).weight(.semibold))
                    .foregroundStyle(Theme.macInk)
                    .lineLimit(1)
                badge(job.scheduleDisplay, icon: "calendar")
                if !job.enabled || job.state == "paused" {
                    badge("paused", icon: "pause.circle")
                }
                Spacer()
                lastStatusBadge(job.lastStatus)
            }

            HStack(spacing: 12) {
                if let script = job.script {
                    metaText("script: \(script)")
                }
                if let lastRun = job.lastRunAt {
                    metaText("last run \(Self.timestamp(lastRun))")
                }
                if let nextRun = job.nextRunAt {
                    metaText("next \(Self.timestamp(nextRun))")
                }
                metaText("completed \(job.completedCount)")
            }

            if let lastError = job.lastError, job.lastStatus == "error" {
                Text(lastError)
                    .font(.caption2.monospaced())
                    .foregroundStyle(Theme.macRed.opacity(0.9))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.macRed.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.macEntry.opacity(0.2), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.macHair, lineWidth: 1))
    }

    // MARK: Harness (native, editable)

    private var harnessSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                subheading("Harness routines")
                badge("headless runs land in the ledger", icon: "tray.full")
                Spacer()
            }

            if let storeError = scheduler.storeError {
                statusLine("Routine store error: \(storeError)", failed: true)
            }

            if showingAddForm {
                addForm
            }

            if scheduler.harnessJobs.isEmpty {
                emptyLine("No native routines yet. Composer sends with a Due date or Nudge register one-shots here.")
            } else {
                ForEach(scheduler.harnessJobs) { job in
                    harnessRow(job)
                }
            }
        }
    }

    private func harnessRow(_ job: RoutineJob) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(job.name)
                    .font(.system(size: 12).weight(.semibold))
                    .foregroundStyle(Theme.macInk)
                    .lineLimit(1)
                badge(job.schedule.display, icon: "calendar")
                if job.state == .paused {
                    badge("paused", icon: "pause.circle")
                }
                if job.state == .done {
                    badge("done", icon: "checkmark.circle")
                }
                Spacer()
                lastStatusBadge(job.lastStatus)
                rowActions(job)
            }

            HStack(spacing: 12) {
                if let lastRun = job.lastRunAt {
                    metaText("last run \(Self.timestamp(lastRun))")
                }
                if let nextRun = job.nextRunAt, job.state == .scheduled {
                    metaText("next \(Self.timestamp(nextRun))")
                }
                metaText("completed \(job.completedCount)")
            }

            if let lastError = job.lastError, job.lastStatus == "error" {
                Text(lastError)
                    .font(.caption2.monospaced())
                    .foregroundStyle(Theme.macRed.opacity(0.9))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.macEntry.opacity(0.2), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.macHair, lineWidth: 1))
    }

    private func rowActions(_ job: RoutineJob) -> some View {
        HStack(spacing: 6) {
            Button {
                Task { await scheduler.runNow(id: job.id) }
            } label: {
                Image(systemName: "play.circle")
            }
            .help("Run now")

            if job.state == .paused {
                Button {
                    scheduler.resume(id: job.id)
                } label: {
                    Image(systemName: "arrow.clockwise.circle")
                }
                .help("Resume")
            } else if job.state == .scheduled {
                Button {
                    scheduler.pause(id: job.id)
                } label: {
                    Image(systemName: "pause.circle")
                }
                .help("Pause")
            }

            Button {
                scheduler.delete(id: job.id)
            } label: {
                Image(systemName: "trash")
            }
            .help("Delete")
        }
        .buttonStyle(.plain)
        .font(.system(size: 13).weight(.semibold))
        .foregroundStyle(Theme.macInk.opacity(0.7))
    }

    // MARK: Add form

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Routine name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)

                Picker("", selection: $newKind) {
                    Text("Every").tag(RoutineSchedule.Kind.interval)
                    Text("Once").tag(RoutineSchedule.Kind.oneshot)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 130)

                if newKind == .interval {
                    Stepper(value: $newMinutes, in: 5...1440, step: 5) {
                        Text("\(newMinutes)m")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.macInk.opacity(0.72))
                    }
                } else {
                    DatePicker("", selection: $newRunAt, displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                }
                Spacer()
            }

            TextField("Prompt the agent runs when this fires", text: $newPrompt, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)

            HStack {
                Spacer()
                Button {
                    addRoutine()
                } label: {
                    Label("Add Routine", systemImage: "plus.circle.fill")
                        .font(.caption.weight(.bold))
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.savyCrimson)
                .disabled(!canAdd)
            }
        }
        .padding(8)
        .background(Theme.macEntry.opacity(0.3), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.macHair, lineWidth: 1))
    }

    private var canAdd: Bool {
        !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !newPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func addRoutine() {
        let schedule: RoutineSchedule = newKind == .interval
            ? .interval(minutes: newMinutes)
            : .oneshot(at: newRunAt)
        scheduler.add(RoutineDraft(
            name: newName.trimmingCharacters(in: .whitespacesAndNewlines),
            prompt: newPrompt.trimmingCharacters(in: .whitespacesAndNewlines),
            schedule: schedule
        ))
        newName = ""
        newPrompt = ""
        showingAddForm = false
    }

    // MARK: Small pieces

    private func subheading(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.bold))
            .foregroundStyle(Theme.macInk.opacity(0.58))
    }

    private func badge(_ text: String, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(text)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(Theme.macInk.opacity(0.62))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Theme.macEntry.opacity(0.4), in: Capsule())
        .overlay(Capsule().stroke(Theme.macHair, lineWidth: 1))
    }

    /// The job's last_status rendered verbatim — "ok" quiet, "error" loud.
    private func lastStatusBadge(_ status: String?) -> some View {
        Group {
            if let status {
                Text(status)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(status == "error" ? Theme.macRed : Theme.macInk.opacity(0.62))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        (status == "error" ? Theme.macRed.opacity(0.1) : Theme.macEntry.opacity(0.4)),
                        in: Capsule()
                    )
                    .overlay(Capsule().stroke(status == "error" ? Theme.macRed.opacity(0.4) : Theme.macHair, lineWidth: 1))
            }
        }
    }

    private func metaText(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(Theme.macInk.opacity(0.46))
            .lineLimit(1)
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Theme.macInk.opacity(0.5))
            .padding(.vertical, 2)
    }

    private func statusLine(_ text: String, failed: Bool) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(failed ? Theme.macRed.opacity(0.9) : Theme.macInk.opacity(0.6))
            .fixedSize(horizontal: false, vertical: true)
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static func timestamp(_ date: Date) -> String {
        timestampFormatter.string(from: date)
    }
}
#endif
