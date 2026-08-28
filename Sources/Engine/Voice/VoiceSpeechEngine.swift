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
                    print("[VoiceEngine] Speech recognition not authorized.")
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
            print("[VoiceEngine] AudioEngine start failed: \(error.localizedDescription)")
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
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.52
        utterance.pitchMultiplier = 1.0

        isSpeaking = true
        speechSynthesizer.speak(utterance)
    }

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
