import Foundation
import Observation

/// The slow work done on a note's saved audio after recording or importing: transcribing it
/// again word by word, telling voices apart, and dropping call audio the microphone heard
/// twice. It runs in the background, one job at a time, so the note stays usable (and
/// deletable) meanwhile. Any job can be skipped, and a job that stops making progress is
/// stopped automatically — the live transcript is kept as it was either way.
@MainActor
@Observable
final class PostProcessor {
    struct Job: Identifiable, Sendable {
        let id = UUID()
        let noteID: UUID
        /// Rebuild only the recording that starts here in the note (nil: all its audio).
        var onlyFrom: Double?
        var detectSpeakers: Bool
        /// Shown while it runs, e.g. "Detecting speakers".
        var title: String
        /// Shown when it's done (nil: nothing to say).
        var doneMessage: String?
        /// Audio files to delete when the job ends, whatever happens ("Save audio" off).
        var deleteAfter: [String] = []
    }

    private(set) var current: Job?
    private(set) var queued: [Job] = []
    private(set) var message = ""
    private(set) var progress: Double = 0
    /// One line about how the last job went, when there's something to say.
    var notice: String?

    /// Stop a job that hasn't reported progress for this long.
    static let stallLimit: TimeInterval = 180

    @ObservationIgnored private weak var store: NoteStore?
    @ObservationIgnored private var runner: Task<Void, Never>?
    @ObservationIgnored private var lastProgress = Date()
    @ObservationIgnored private var stopReason: StopReason?

    private enum StopReason { case skipped, stalled, noteDeleted }

    var isWorking: Bool { current != nil }

    func isBusy(with noteID: UUID) -> Bool {
        current?.noteID == noteID || queued.contains { $0.noteID == noteID }
    }

    func enqueue(_ job: Job, store: NoteStore) {
        self.store = store
        queued.append(job)
        runNext()
    }

    /// Stop the current job; the note keeps its live transcript.
    func skip() {
        guard let current, runner != nil else { return }
        ActivityLog.add("\(current.title): skipped")
        stopReason = .skipped
        runner?.cancel()
    }

    /// The note is being deleted: drop its work.
    func cancel(noteID: UUID) {
        queued.removeAll { $0.noteID == noteID }
        if current?.noteID == noteID, runner != nil {
            ActivityLog.add("\(current?.title ?? "Job"): stopped because the note was deleted")
            stopReason = .noteDeleted
            runner?.cancel()
        }
    }

    // MARK: Running

    private func runNext() {
        guard runner == nil, !queued.isEmpty, let store else { return }
        let job = queued.removeFirst()
        current = job
        message = job.title + "…"
        progress = 0
        lastProgress = Date()
        stopReason = nil
        runner = Task { [weak self] in
            await self?.run(job, store: store)
            guard let self else { return }
            self.current = nil
            self.runner = nil
            self.message = ""
            self.progress = 0
            self.runNext()
        }
    }

    private func run(_ job: Job, store: NoteStore) async {
        let started = Date()
        ActivityLog.add("\(job.title): started")
        let watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled, self.current?.id == job.id else { return }
                if Date().timeIntervalSince(self.lastProgress) > Self.stallLimit {
                    ActivityLog.add("\(job.title): no progress for \(Int(Self.stallLimit)) s — stopping it")
                    self.stopReason = .stalled
                    self.runner?.cancel()
                    return
                }
            }
        }
        defer { watchdog.cancel() }

        do {
            try await Race.run(job.title) {
                try await SpeakerPass.run(
                    noteID: job.noteID, store: store, onlyFrom: job.onlyFrom, detectSpeakers: job.detectSpeakers
                ) { update in
                    Task { @MainActor [weak self] in self?.report(update, for: job.id) }
                }
            }
            ActivityLog.add("\(job.title): done in \(Int(Date().timeIntervalSince(started))) s")
            if let done = job.doneMessage { notice = done }
        } catch {
            switch stopReason {
            case .noteDeleted:
                break
            case .skipped:
                notice = "Skipped. The live transcript was kept — use “From audio” on the Transcript tab to try again."
            case .stalled:
                notice = "\(job.title) stopped making progress, so Sintr stopped it. The live transcript was kept."
            case nil:
                ActivityLog.add("\(job.title): failed (\(error.localizedDescription))")
                notice = "\(job.title) didn't finish: \(error.localizedDescription) The live transcript was kept."
            }
        }
        deleteFiles(of: job, store: store)
    }

    private func report(_ update: SpeakerPass.Progress, for jobID: UUID) {
        guard current?.id == jobID else { return }  // A late update from a job that's over.
        message = update.message
        progress = update.fraction
        lastProgress = Date()
    }

    private func deleteFiles(of job: Job, store: NoteStore) {
        guard !job.deleteAfter.isEmpty else { return }
        for name in job.deleteAfter { try? FileManager.default.removeItem(at: store.recordingURL(name)) }
        let names = Set(job.deleteAfter)
        if store.note(job.noteID) != nil {
            store.edit(job.noteID) { $0.recordings.removeAll { names.contains($0.fileName) } }
            store.saveNow()
        }
    }
}
