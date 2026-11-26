import Foundation
import Speech
import AVFoundation
import Accelerate

final class SpeechRecognizerManager {
	private let recognizer = SFSpeechRecognizer()//locale: Locale(identifier: Locale.current.identifier.hasPrefix("en_GB") ? "en-GB" : "en-US"))
	private var request: SFSpeechAudioBufferRecognitionRequest?
	private var task: SFSpeechRecognitionTask?
	private var engine: AVAudioEngine?
	private var activeCaptureID: UUID?

	nonisolated func requestPermissions() async -> Bool {
		let authorized = await withCheckedContinuation { continuation in
			SFSpeechRecognizer.requestAuthorization { status in
				continuation.resume(returning: status == .authorized)
			}
		}
		guard authorized else { return false }
		#if os(macOS)
		return await AVCaptureDevice.requestAccess(for: .audio)
		#else
		return await AVAudioApplication.requestRecordPermission()
		#endif
	}

	var microphoneName: String {
		#if os(iOS) || os(visionOS)
		return AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName ?? "Microphone"
		#else
		return "Microphone"
		#endif
	}

	func startListening(contextualStrings: [String] = [],
						onLevel: @escaping @MainActor (Float) -> Void,
						onResult: @escaping ([String], Bool, Error?) -> Void) async throws {
		stopListening()
		guard let recognizer, recognizer.isAvailable else {
			throw RecordingError("Speech recognition is unavailable.")
		}
		do {
			try await AudioSessionManager.shared.activate(.recording)
		} catch is CancellationError {
			throw CancellationError()
		} catch {
			AudioSessionManager.shared.end(.recording)
			throw error
		}
		let engine = AVAudioEngine()
		let input = engine.inputNode
		let format = input.outputFormat(forBus: 0)
		guard format.sampleRate > 0, format.channelCount > 0 else {
			AudioSessionManager.shared.end(.recording)
			throw RecordingError("Connect or select a microphone and try again.")
		}

		let request = SFSpeechAudioBufferRecognitionRequest()
		request.shouldReportPartialResults = true
		request.taskHint = .dictation
		request.contextualStrings = Array(contextualStrings.prefix(100))
		request.requiresOnDeviceRecognition = false
		self.request = request
		let captureID = UUID()
		activeCaptureID = captureID
		do {
			try input.installAudioTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] audio, _ in
				guard audio.frameLength > 0 else { return }
				DispatchQueue.main.async {
					guard let self, self.activeCaptureID == captureID, let request = self.request else { return }
					let buffer = AVAudioPCMBuffer(copying: audio)
					request.append(buffer)
					guard let channels = buffer.floatChannelData else { return }
					var rms: Float = 0
					for channel in 0..<Int(buffer.format.channelCount) {
						var channelRMS: Float = 0
						vDSP_rmsqv(channels[channel], vDSP_Stride(buffer.stride), &channelRMS, vDSP_Length(buffer.frameLength))
						rms = max(rms, channelRMS)
					}
					onLevel(20 * log10(max(rms, 0.000001)))
				}
			}
		} catch {
			stopListening()
			throw error
		}
		self.engine = engine

		task = recognizer.recognitionTask(with: request) { [weak self, weak request] result, error in
			DispatchQueue.main.async {
				guard let self, let request, self.request === request else { return }
				let finished = result?.isFinal == true || error != nil || self.m_debugString != nil
				let readings = if self.m_debugString != nil { [ self.m_debugString! ] } else { result.map { [$0.bestTranscription.formattedString] + $0.transcriptions.map(\.formattedString) } ?? [] }
				var seen = Set<String>()
				onResult(readings.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }, finished, error)
			}
		}
		engine.prepare()
		do {
			try engine.start()
		} catch {
			stopListening()
			throw error
		}
	}
	private var m_debugString: String?

	func finishAudio() {
		activeCaptureID = nil
		guard let engine else {
			AudioSessionManager.shared.end(.recording)
			return
		}
		engine.stop()
		engine.inputNode.removeTap(onBus: 0)
		self.engine = nil
		request?.endAudio()
		AudioSessionManager.shared.end(.recording)
	}

	func resetCapture() {
		stopListening()
	}

	func stopListening() {
		finishAudio()
		request = nil
		task?.cancel()
		task = nil
	}
}

private struct RecordingError: LocalizedError {
	let errorDescription: String?
	init(_ message: String) { errorDescription = message }
}
