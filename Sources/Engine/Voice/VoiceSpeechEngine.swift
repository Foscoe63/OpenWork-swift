import Foundation
import AVFoundation
import Speech
import Combine

@MainActor
public final class VoiceSpeechEngine: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    public static let shared = VoiceSpeechEngine()

    @Published public var isRecording: Bool = false
    @Published public var isSpeaking: Bool = false
    @Published public var transcript: String = ""
    @Published public var audioLevels: Float = 0.0
    /// Why the last dictation attempt did not start, for the composer to show. Cleared on read.
    @Published public var lastError: String?

    private var audioEngine = AVAudioEngine()
    private var speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    private let speechSynthesizer = AVSpeechSynthesizer()

    override private init() {
        super.init()
        speechSynthesizer.delegate = self
    }

    public func toggleDictation(onResult: @escaping (String) -> Void) {
        if isRecording {
            stopRecording()
        } else {
            startRecording(onResult: onResult)
        }
    }

    public func startRecording(onResult: @escaping (String) -> Void) {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard status == .authorized else {
                    // Was a `print`, so a denied permission made the mic button do nothing at all.
                    self?.lastError = status == .restricted
                        ? "Speech recognition is restricted on this Mac."
                        : "Dictation needs Speech Recognition access — allow SwiftOpenWork in System Settings › Privacy & Security."
                    return
                }
                self?.beginAudioCapture(onResult: onResult)
            }
        }
    }

    private func beginAudioCapture(onResult: @escaping (String) -> Void) {
        stopRecording()

        audioEngine = AVAudioEngine()
        let node = audioEngine.inputNode
        let recordingFormat = node.outputFormat(forBus: 0)

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let request = recognitionRequest else { return }
        request.shouldReportPartialResults = true

        recognitionTask = speechRecognizer?.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }
            if let res = result {
                let text = res.bestTranscription.formattedString
                self.transcript = text
                onResult(text)
            }
            if error != nil || (result?.isFinal ?? false) {
                self.stopRecording()
            }
        }

        node.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
            isRecording = true
        } catch {
            lastError = "Could not start the microphone: \(error.localizedDescription)"
            stopRecording()
        }
    }

    public func stopRecording() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        isRecording = false
    }

    // MARK: - Text to Speech
    public func speak(text: String) {
        stopSpeaking()
        let cleanText = text
            .replacingOccurrences(of: "```[a-zA-Z0-9_-]*", with: "", options: .regularExpression)
            .replacingOccurrences(of: "```", with: "")
            .replacingOccurrences(of: "#", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanText.isEmpty else { return }

        let utterance = AVSpeechUtterance(string: cleanText)
        utterance.voice = Self.preferredVoice()
        utterance.rate = 0.52
        utterance.pitchMultiplier = 1.0

        isSpeaking = true
        speechSynthesizer.speak(utterance)
    }

    /// The voice named by `speechVoiceIdentifier`, or the system default for en-US.
    ///
    /// That setting was stored, defaulted to Alex, had no control anywhere in the UI, and was
    /// never read: every utterance used `AVSpeechSynthesisVoice(language: "en-US")`. The
    /// identifier can also name a voice that is not installed on this Mac — installed voices are
    /// per-user downloads — so a miss has to fall back rather than go silent.
    static func preferredVoice() -> AVSpeechSynthesisVoice? {
        let identifier = PersistenceManager.shared.loadSettings().speechVoiceIdentifier
        if !identifier.isEmpty, let voice = AVSpeechSynthesisVoice(identifier: identifier) {
            return voice
        }
        return AVSpeechSynthesisVoice(language: "en-US")
    }

    /// `identifier` if it names a voice installed here, otherwise "" for the system default.
    ///
    /// The picker and `preferredVoice()` have to agree about an identifier that does not resolve,
    /// or the UI claims a voice that speech is not using.
    public static func resolvedVoiceIdentifier(_ identifier: String) -> String {
        guard !identifier.isEmpty, AVSpeechSynthesisVoice(identifier: identifier) != nil else { return "" }
        return identifier
    }

    /// Voices actually installed for this user, for the settings picker to offer.
    ///
    /// Cached because the picker asks for this from a SwiftUI body, and enumerating the installed
    /// voices is not free. The set only changes when the user downloads a voice in System
    /// Settings, which does not happen while this picker is on screen.
    public static func installedVoices() -> [AVSpeechSynthesisVoice] {
        if let cached = cachedInstalledVoices { return cached }
        let voices = AVSpeechSynthesisVoice.speechVoices()
            .sorted { ($0.language, $0.name) < ($1.language, $1.name) }
        cachedInstalledVoices = voices
        return voices
    }

    private static var cachedInstalledVoices: [AVSpeechSynthesisVoice]?

    public func stopSpeaking() {
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
        isSpeaking = false
    }

    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
        }
    }

    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
        }
    }
}
