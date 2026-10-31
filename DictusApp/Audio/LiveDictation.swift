// DictusApp/Audio/LiveDictation.swift
// Self-hosted fork: live text while dictating, with FluidAudio's streaming Parakeet.
import AVFoundation
import Foundation
import DictusCore
import FluidAudio

/// Files of the streaming model, and where they live on disk.
///
/// The model is Parakeet Unified 0.6B (English), from the same publisher as the Parakeet
/// and Nemotron models Dictus already uses. It streams: it emits words about 0.6 s after
/// they are spoken, and it only ever APPENDS to its transcript (each chunk's tokens are
/// final), which is what makes inserting live text into a text field safe.
///
/// Only one latency tier is downloaded: 640 ms ([70,7,1], int8 encoder). FluidAudio
/// documents it as the same WER as the 320 ms tier at about 2.5x less compute, so it is
/// the better choice for battery in a background app.
enum LiveModelFiles {
    static let repositoryID = "FluidInference/parakeet-unified-en-0.6b-coreml"
    static let modelName = "parakeet-unified-en-640ms"

    static let config = UnifiedConfig(leftFrames: 70, chunkFrames: 7, rightFrames: 1)

    static var encoderBundle: String {
        ModelNames.ParakeetUnified.streamingEncoderFile(precision: .int8, contextSuffix: config.contextSuffix)
    }

    static var requiredBundles: [String] {
        [encoderBundle, ModelNames.ParakeetUnified.decoderFile, ModelNames.ParakeetUnified.jointDecisionFile]
    }

    static var rootFiles: [String] { [ModelNames.ParakeetUnified.vocab] }

    static var directory: URL {
        MLModelConfigurationUtils.defaultModelsDirectory(for: .parakeetUnified)
    }

    static func requiredPaths() -> [String] {
        requiredBundles.flatMap { bundle in
            ParakeetModelRepository.requiredBundleEntries.map { "\(bundle)/\($0)" }
        } + rootFiles
    }

    static var isInstalled: Bool {
        let fileManager = FileManager.default
        return requiredPaths().allSatisfy {
            fileManager.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }

    static var downloaderConfiguration: ModelRepoDownloader.Configuration {
        ModelRepoDownloader.Configuration(
            repoPath: repositoryID,
            directoryPatterns: requiredBundles.map { "\($0)/" },
            includesRootMetadata: true,
            requiredPaths: { _ in LiveModelFiles.requiredPaths() }
        )
    }
}

/// Runs the streaming model during a dictation and publishes the growing transcript to
/// the keyboard through `LiveTextChannel`.
///
/// Lifecycle, driven by `DictationCoordinator`:
/// - `begin(engine:)` right after the microphone starts recording. Returns false when live
///   text cannot be used (setting off, language not English, model missing or failed to load,
///   dictation started from the app itself). The coordinator then keeps today's behaviour.
/// - `finish()` at stop. Returns the final transcript of a live session, or nil.
/// - `cancel()` when the dictation is cancelled.
@MainActor
final class LiveDictation: ObservableObject {
    static let shared = LiveDictation()

    // MARK: - Download state (Settings UI)

    @Published private(set) var isInstalled = LiveModelFiles.isInstalled
    @Published private(set) var downloadFraction: Double?
    @Published private(set) var downloadError: String?

    // MARK: - Session state

    private var manager: StreamingUnifiedAsrManager?
    private var loadTask: Task<StreamingUnifiedAsrManager?, Never>?

    private var sessionID: String?
    private var continuation: AsyncStream<[Float]>.Continuation?
    private var consumer: Task<Void, Never>?
    private var lastPublished = ""
    private weak var engine: UnifiedAudioEngine?

    /// True from a successful `begin` until `finish`/`cancel`.
    var isActive: Bool { sessionID != nil }

    /// Whether any text reached the keyboard in the current session.
    var hasPublishedText: Bool { !lastPublished.isEmpty }

    private init() {}

    // MARK: - Eligibility

    /// Live text needs the setting on, English, and the model on disk.
    static var isUsable: Bool {
        guard LiveTextChannel.isEnabled, LiveModelFiles.isInstalled else { return false }
        let language = AppGroup.defaults.string(forKey: SharedKeys.language) ?? "en"
        return language.hasPrefix("en")
    }

    // MARK: - Download

    func download() {
        guard downloadFraction == nil else { return }
        downloadFraction = 0
        downloadError = nil
        PersistentLog.log(.diagnosticProbe(
            component: "LiveText", instanceID: LiveModelFiles.modelName,
            action: "downloadStarted", details: "repo=\(LiveModelFiles.repositoryID)"
        ))
        Task {
            do {
                let downloader = ModelRepoDownloader(configuration: LiveModelFiles.downloaderConfiguration)
                try await downloader.download(
                    to: LiveModelFiles.directory,
                    modelName: LiveModelFiles.modelName
                ) { progress in
                    Task { @MainActor in
                        if LiveDictation.shared.downloadFraction != nil {
                            LiveDictation.shared.downloadFraction = progress.fraction
                        }
                    }
                }
                downloadFraction = nil
                isInstalled = LiveModelFiles.isInstalled
                PersistentLog.log(.diagnosticProbe(
                    component: "LiveText", instanceID: LiveModelFiles.modelName,
                    action: "downloadFinished", details: "installed=\(isInstalled)"
                ))
                prewarm()
            } catch {
                downloadFraction = nil
                downloadError = error.localizedDescription
                PersistentLog.log(.diagnosticProbe(
                    component: "LiveText", instanceID: LiveModelFiles.modelName,
                    action: "downloadFailed", details: error.localizedDescription
                ))
            }
        }
    }

    func deleteModel() {
        cancel()
        manager = nil
        loadTask = nil
        try? FileManager.default.removeItem(at: LiveModelFiles.directory)
        isInstalled = LiveModelFiles.isInstalled
        publishAvailability()
    }

    /// Tells the keyboard whether the model is installed (see `LiveTextChannel.isExpected`).
    func publishAvailability() {
        AppGroup.defaults.set(LiveModelFiles.isInstalled, forKey: LiveTextChannel.modelInstalledKey)
    }

    // MARK: - Model load

    /// Starts loading the model in the background, if live text is usable.
    func prewarm() {
        publishAvailability()
        guard Self.isUsable else { return }
        _ = startLoadIfNeeded()
    }

    private func startLoadIfNeeded() -> Task<StreamingUnifiedAsrManager?, Never> {
        if let loadTask { return loadTask }
        let task = Task<StreamingUnifiedAsrManager?, Never> { @MainActor in
            let holder = "liveText"
            let startedAt = Date()
            do {
                // One Core ML compile at a time: the Neural Engine crashes when two
                // models compile at once (see `DictationCoordinator.neuralEngineHolder`).
                try await DictationCoordinator.shared.acquireNeuralEngine(for: holder)
                defer { DictationCoordinator.shared.releaseNeuralEngine(from: holder) }
                let manager = StreamingUnifiedAsrManager(config: LiveModelFiles.config, encoderPrecision: .int8)
                try await manager.loadModels(from: LiveModelFiles.directory)
                self.manager = manager
                PersistentLog.log(.diagnosticProbe(
                    component: "LiveText", instanceID: LiveModelFiles.modelName, action: "loaded",
                    details: "ms=\(Int(Date().timeIntervalSince(startedAt) * 1000))"
                ))
                return manager
            } catch {
                PersistentLog.log(.diagnosticProbe(
                    component: "LiveText", instanceID: LiveModelFiles.modelName, action: "loadFailed",
                    details: error.localizedDescription
                ))
                self.loadTask = nil   // allow a later retry
                return nil
            }
        }
        loadTask = task
        return task
    }

    // MARK: - Session

    /// Starts a live session. Audio recorded before the model is ready is kept and
    /// processed as soon as it is, so no words are lost on a cold start.
    @discardableResult
    func begin(engine: UnifiedAudioEngine) -> Bool {
        cancel()
        guard Self.isUsable else { return false }

        let session = UUID().uuidString
        sessionID = session
        lastPublished = ""
        self.engine = engine
        LiveTextChannel.begin(session: session)

        let (stream, continuation) = AsyncStream<[Float]>.makeStream()
        self.continuation = continuation
        engine.onRecordedSamples = { samples in
            continuation.yield(samples)
        }

        let loadTask = startLoadIfNeeded()
        consumer = Task { @MainActor [weak self] in
            guard let manager = await loadTask.value else {
                self?.abandon(session: session, reason: "model not loaded")
                return
            }
            do {
                try await manager.reset()
                for await samples in stream {
                    guard let buffer = Self.makeBuffer(samples) else { continue }
                    try await manager.appendAudio(buffer)
                    try await manager.processBufferedAudio()
                    let text = await manager.getPartialTranscript()
                    self?.publish(text, session: session)
                }
            } catch {
                PersistentLog.log(.diagnosticProbe(
                    component: "LiveText", instanceID: session, action: "streamFailed",
                    details: error.localizedDescription
                ))
            }
        }

        PersistentLog.log(.diagnosticProbe(
            component: "LiveText", instanceID: session, action: "began",
            details: "modelReady=\(manager != nil)"
        ))
        return true
    }

    /// Ends the session and returns its final transcript. Nil when no session is active.
    func finish() async -> String? {
        guard let session = sessionID else { return nil }
        engine?.onRecordedSamples = nil
        continuation?.finish()
        continuation = nil
        await consumer?.value
        consumer = nil
        // The model failed to load and the session was abandoned: no live result. The
        // coordinator then transcribes the recording the normal way.
        guard sessionID == session else { return nil }

        var finalText = lastPublished
        if let manager, sessionID == session {
            if let text = try? await manager.finish() {
                finalText = text
            }
            try? await manager.reset()
        }
        // The keyboard must see every word before the hand-off, so the hand-off's final
        // text always starts with what the keyboard already inserted.
        publish(finalText, session: session)
        PersistentLog.log(.diagnosticProbe(
            component: "LiveText", instanceID: session, action: "finished",
            details: "chars=\(finalText.count)"
        ))
        sessionID = nil
        engine = nil
        return finalText
    }

    /// The id of the active session, used to mark the hand-off as live.
    var currentSessionID: String? { sessionID }

    /// Stops the session without a result.
    func cancel() {
        guard sessionID != nil else { return }
        engine?.onRecordedSamples = nil
        continuation?.finish()
        continuation = nil
        consumer?.cancel()
        consumer = nil
        sessionID = nil
        engine = nil
        lastPublished = ""
        LiveTextChannel.clear()
        if let manager { Task { try? await manager.reset() } }
    }

    // MARK: - Helpers

    private func publish(_ text: String, session: String) {
        guard sessionID == session, text != lastPublished else { return }
        lastPublished = text
        LiveTextChannel.publish(session: session, text: text)
    }

    /// A session whose model could not load. If nothing reached the keyboard yet, the
    /// coordinator falls back to the normal transcription at stop.
    private func abandon(session: String, reason: String) {
        guard sessionID == session else { return }
        PersistentLog.log(.diagnosticProbe(
            component: "LiveText", instanceID: session, action: "abandoned", details: reason
        ))
        engine?.onRecordedSamples = nil
        continuation?.finish()
        continuation = nil
        sessionID = nil
        engine = nil
        LiveTextChannel.clear()
    }

    private static let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false
    )

    private static func makeBuffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
        guard let format, !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: samples.count)
        }
        return buffer
    }
}
