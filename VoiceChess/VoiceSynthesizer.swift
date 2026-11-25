import AVFoundation

@MainActor final class VoiceSynthesizer: NSObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
	private let synthesizer = AVSpeechSynthesizer()
	private let listeningBeep = ListeningBeep()
	private var beepTask: Task<Void, Never>?
	private var boardSegments: [String] = []
	private var boardSequenceActive = false
	private var boardSequenceGeneration = 0
	private var fallbackUtteranceID: ObjectIdentifier?
	private var speechPlayer: AVAudioPlayer?
	private var speechTask: Task<Void, Never>?
	private var boardPauseTask: Task<Void, Never>?
	var onSpeechFinished: (() -> Void)?
	
	override init() {
		super.init()
		synthesizer.delegate = self
	}
	
	var isSpeaking: Bool {
		return speechTask != nil || speechPlayer?.isPlaying == true || synthesizer.isSpeaking
	}
	
	func stopSpeaking() {
		beepTask?.cancel()
		boardPauseTask?.cancel()
		boardPauseTask = nil
		boardSequenceGeneration += 1
		boardSequenceActive = false
		fallbackUtteranceID = nil
		speechTask?.cancel()
		speechTask = nil
		speechPlayer?.stop()
		speechPlayer = nil
		boardSegments = []
		if synthesizer.isSpeaking {
			synthesizer.stopSpeaking(at: .immediate)
		}
		AudioSessionManager.shared.end(.playback)
	}
	
	func playListeningBeep() {
		beepTask?.cancel()
		beepTask = Task { await listeningBeep.play() }
	}

	func speak(_ text: String) {
		speak(text, rate: AVSpeechUtteranceDefaultSpeechRate * 0.95)
	}

	func speakBoard(_ text: String) {
		stopSpeaking()
		let segments = text.split(separator: ".")
			.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
			.filter { !$0.isEmpty }
			.map { "\($0)." }
		guard !segments.isEmpty else { return }
		boardSegments = segments
		boardSequenceActive = true
		let generation = boardSequenceGeneration
		speakNextBoardSegment(generation: generation, activateSession: true)
	}

	private func speak(_ text: String, rate: Float) {
		stopSpeaking()
		speakUtterance(text, rate: rate)
	}

	private func speakNextBoardSegment(generation: Int, activateSession: Bool = false) {
		guard boardSequenceActive, generation == boardSequenceGeneration,
			  !boardSegments.isEmpty else { return }
		let segment = boardSegments.removeFirst()
		speakUtterance(segment, rate: AVSpeechUtteranceDefaultSpeechRate * 0.72, activateSession: activateSession)
	}

	private func speakUtterance(_ text: String, rate: Float, activateSession: Bool = true) {
		let generation = boardSequenceGeneration
		speechTask = Task { @MainActor in
			guard generation == boardSequenceGeneration else { return }
			do {
				if activateSession {
					try await AudioSessionManager.shared.activate(.playback)
				}
			} catch is CancellationError {
				return
			} catch {
				print("Unable to activate speech playback: \(error.localizedDescription)")
			}
			guard generation == boardSequenceGeneration else { return }
			let utterance = AVSpeechUtterance(string: uppercasedChessSquares(in: text))
			let language = Locale.current.identifier.hasPrefix("en-GB") ? "en-GB" : "en-US"
			utterance.voice = await Self.preferredVoice(for: language)
			guard !Task.isCancelled else { return }
			utterance.rate = rate
			do {
				let (buffers, continuation) = AsyncStream<AVReadOnlyAudioPCMBuffer>.makeStream()
				synthesizer.write(utterance) { @Sendable buffer in
					guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
						continuation.finish()
						return
					}
					continuation.yield(AVReadOnlyAudioPCMBuffer(copying: pcm))
				}
				let player = try await Self.renderedPlayer(from: buffers)
				try Task.checkCancellation()
				player.delegate = self
				speechPlayer = player
				guard player.play() else { throw SpeechPlaybackError() }
			} catch is CancellationError {
				return
			} catch {
				guard !Task.isCancelled else { return }
				speechPlayer = nil
				print("Unable to play rendered speech: \(error.localizedDescription)")
				// Some installed voices may only support direct speech playback.
				let fallback = utterance.copy() as! AVSpeechUtterance
				fallbackUtteranceID = ObjectIdentifier(fallback)
				synthesizer.speak(fallback)
			}
			speechTask = nil
		}
	}

	@concurrent private static func renderedPlayer(from buffers: AsyncStream<AVReadOnlyAudioPCMBuffer>) async throws -> sending AVAudioPlayer {
		let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
		defer { try? FileManager.default.removeItem(at: url) }
		var file: AVAudioFile?
		for await buffer in buffers {
			try Task.checkCancellation()
			let format = buffer.format
			if file == nil {
				file = try AVAudioFile(forWriting: url, settings: format.settings,
									   commonFormat: format.commonFormat, interleaved: format.isInterleaved)
			}
			try file?.write(from: buffer)
		}
		try Task.checkCancellation()
		guard let output = file, output.length > 0 else { throw SpeechPlaybackError() }
		output.close()
		let player = try AVAudioPlayer(data: Data(contentsOf: url))
		guard player.prepareToPlay() else { throw SpeechPlaybackError() }
		return player
	}

	private func uppercasedChessSquares(in text: String) -> String {
		guard let regex = try? NSRegularExpression(
			pattern: "(?<![A-Za-z0-9])[a-h][1-8](?![A-Za-z0-9])",
			options: [.caseInsensitive]
		) else { return text }
		let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
		var result = text
		for match in regex.matches(in: text, range: fullRange).reversed() {
			guard let range = Range(match.range, in: result) else { continue }
			result.replaceSubrange(range, with: result[range].uppercased())
		}
		return result
	}

	private static func preferredVoice(for language: String) async -> AVSpeechSynthesisVoice? {
		let qualityRank: [AVSpeechSynthesisVoiceQuality: Int] = [
			.default: 0,
			.enhanced: 1,
			.premium: 2
		]
		// The synchronous voice catalog calls into AXCoreUtilities and can block a Swift task.
		return await withCheckedContinuation { continuation in
			DispatchQueue.global(qos: .userInitiated).async {
				let matching = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == language }
				let best = matching.max {
					(qualityRank[$0.quality] ?? 0) < (qualityRank[$1.quality] ?? 0)
				}
				continuation.resume(returning: best ?? AVSpeechSynthesisVoice(language: language))
			}
		}
	}
	
	nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
		let utteranceID = ObjectIdentifier(utterance)
		DispatchQueue.main.async { [weak self] in
			guard let self, fallbackUtteranceID == utteranceID else { return }
			fallbackUtteranceID = nil
			finishUtterance()
		}
	}

	nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
		let id = ObjectIdentifier(player)
		DispatchQueue.main.async { [weak self] in
			guard let self, let active = speechPlayer, ObjectIdentifier(active) == id else { return }
			speechPlayer = nil
			finishUtterance()
		}
	}

	private func finishUtterance() {
		if boardSequenceActive {
			let generation = boardSequenceGeneration
			if boardSegments.isEmpty {
				boardSequenceActive = false
				AudioSessionManager.shared.end(.playback)
				onSpeechFinished?()
			} else {
				boardPauseTask = Task { @MainActor [weak self] in
					try? await Task.sleep(for: .milliseconds(850))
					guard let self, boardSequenceActive, generation == boardSequenceGeneration else { return }
					boardPauseTask = nil
					speakNextBoardSegment(generation: generation)
				}
			}
			return
		}
		AudioSessionManager.shared.end(.playback)
		onSpeechFinished?()
	}
}

private struct SpeechPlaybackError: LocalizedError {
	var errorDescription: String? { "No playable speech audio was produced." }
}

private actor ListeningBeep {
	private var beepPlayer: AVAudioPlayer?

	func play() {
		guard !Task.isCancelled else { return }
		beepPlayer?.stop()
		do {
			let player = try AVAudioPlayer(data: Self.listeningBeepWaveform())
			player.volume = 0.8
			player.prepareToPlay()
			beepPlayer = player
			guard !Task.isCancelled else { return }
			if !player.play() {
				print("Unable to start the listening beep.")
			}
		} catch {
			print("Unable to play listening beep: \(error.localizedDescription)")
		}
	}

	private static func listeningBeepWaveform() -> Data {
		let sampleRate = 44_100
		let frameCount = Int(Double(sampleRate) * 0.14)
		let sampleByteCount = frameCount * MemoryLayout<Int16>.size
		var data = Data()
		data.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // RIFF
		append(UInt32(36 + sampleByteCount), to: &data)
		data.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // WAVE
		data.append(contentsOf: [0x66, 0x6d, 0x74, 0x20]) // fmt 
		append(UInt32(16), to: &data)
		append(UInt16(1), to: &data) // PCM
		append(UInt16(1), to: &data) // mono
		append(UInt32(sampleRate), to: &data)
		append(UInt32(sampleRate * 2), to: &data)
		append(UInt16(2), to: &data)
		append(UInt16(16), to: &data)
		data.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // data
		append(UInt32(sampleByteCount), to: &data)

		for frame in 0..<frameCount {
			let time = Double(frame) / Double(sampleRate)
			let fade = min(1.0, min(Double(frame) / 220.0, Double(frameCount - frame - 1) / 220.0))
			let sample = sin(2 * Double.pi * 880 * time) * 0.3 * fade
			append(Int16(sample * Double(Int16.max)), to: &data)
		}
		return data
	}

	private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
		var littleEndianValue = value.littleEndian
		withUnsafeBytes(of: &littleEndianValue) { data.append(contentsOf: $0) }
	}
}
