import AVFoundation

@MainActor final class AudioSessionManager {
	static let shared = AudioSessionManager()

	enum Use {
		case recording, playback
	}

	private var currentUse: Use?
	private var generation = 0
	private var transition: Task<Void, Error>?

	private init() {}

	func activate(_ use: Use) async throws {
		generation += 1
		let requestedGeneration = generation
		currentUse = use
		let previous = transition
		let activation = Task<Void, Error> {
			_ = await previous?.result
			guard generation == requestedGeneration else { throw CancellationError() }
			#if os(iOS) || os(visionOS)
			try await Self.configureAndActivate(use)
			#endif
		}
		transition = activation
		let result = await activation.result
		guard generation == requestedGeneration else { throw CancellationError() }
		transition = nil
		try result.get()
	}

	#if os(iOS) || os(visionOS)
	@concurrent private static func configureAndActivate(_ use: Use) async throws {
		let session = AVAudioSession.sharedInstance()
		switch use {
		case .recording:
			try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP])
		case .playback:
			try session.setCategory(.playback, mode: .spokenAudio)
		}
		guard try await session.activate(options: []) else { throw SessionActivationError() }
	}
	#endif

	func end(_ use: Use) {
		guard currentUse == use else { return }
		currentUse = nil
		generation += 1
		let previous = transition
		transition = Task {
			_ = await previous?.result
			#if os(iOS) || os(visionOS)
			do {
				_ = try await AVAudioSession.sharedInstance().deactivate(options: [.notifyOthersOnDeactivation])
			} catch {
				print("Unable to deactivate audio session: \(error.localizedDescription)")
			}
			#endif
		}
	}
}

private struct SessionActivationError: LocalizedError {
	var errorDescription: String? { "The audio session could not be activated." }
}
