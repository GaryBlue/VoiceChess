import SwiftUI

struct ContentView: View {
	@Environment(\.scenePhase) private var scenePhase
	@StateObject private var coordinator = GameCoordinator()

	private var isListening: Bool {
		if case .listening = coordinator.currentState { return true }
		return false
	}

	var body: some View {
		VStack(spacing: 20) {
			Text("Voice Chess")
				.font(.largeTitle)
				.bold()
			StatusCard(state: coordinator.currentState)
			microphoneMeter
			transcriptDisplay
			commandsDisplay
			movesList
		}
		.padding()
		.task {
			coordinator.beginVoiceSetup()
		}
		.onChange(of: scenePhase) { _, phase in
			switch phase {
			case .background:
				coordinator.stopForBackground()
			case .active:
				coordinator.resumeAfterForeground()
			default:
				break
			}
		}
	}

	private var commandsDisplay: some View {
		let txt = if coordinator.gameStarted {
			"Speak a move\nWhen promoting add 'promote to' followed by\n   queen, rook, bishop or knight (queen is default)\n" +
			"Commands:\n" +
			" • help - announce command help\n" +
			" • hint - get a move suggestion\n" +
			" • repeat - repeat the last move announcement\n" +
			" • undo - undo the last pair of moves\n" +
			" • call out the board - announce the board state\n" +
			" • call out rank N - announce the pieces on one rank\n" +
			" • where are the black bishops? - locate pieces by colour and type\n" +
			" • call out moves - read the move history\n" +
			" • revert to move N - ask before discarding moves after N\n" +
			" • new game - ask to end this session and start a new game\n"
		} else {
			"White: play as white\n" +
			"Black: play as black\n" +
			"Random: pick randomly\n" +
			"Puzzle: play a mate-in- puzzle\n" +
			"Help: announce commands\n" +
			"Game mode difficulty:\n" +
			"   1-8 Maia (Elo 600 to 2000)\n" +
			"   9-11 Stockfish (Elo 2200 to 3000)\n" +
			"   12 Stockfish (full strength)"
		}
		return Text(txt).font(.caption2).multilineTextAlignment(.leading).foregroundStyle(.secondary)
	}

	private var movesList: some View {
		VStack(alignment: .leading, spacing: 2) {
			Text("Moves")
				.font(.caption)
				.foregroundStyle(.secondary)
			ScrollView {
				VStack(alignment: .leading, spacing: 0) {
					if coordinator.moveHistory.isEmpty {
						Text("No moves yet")
							.foregroundStyle(.secondary)
					} else {
						ForEach(coordinator.moveHistory, id: \.self) { move in
							Text(move)
								.font(.caption)
								.frame(maxWidth: .infinity, alignment: .leading)
						}
					}
				}
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
		.opacity(coordinator.moveHistory.isEmpty ? 0.35 : 1)
	}

	private var microphoneMeter: some View {
		ProgressView(value: isListening ? coordinator.inputLevel : 0) {
			Text(coordinator.microphoneName)
		}
		.progressViewStyle(CenteredMicrophoneProgressStyle())
		.accessibilityLabel("Microphone input level, \(coordinator.microphoneName)")
		.opacity(isListening ? 1 : 0.35)
		.frame(minHeight: 24)
	}

	private var transcriptDisplay: some View {
		Text(coordinator.transcript.isEmpty ? "Heard: —" : "Heard: \(coordinator.transcript)")
			.multilineTextAlignment(.center)
			.foregroundStyle(coordinator.transcript.isEmpty ? .secondary : .primary)
			.opacity(coordinator.transcript.isEmpty ? 0.45 : 1)
			.frame(maxWidth: .infinity, minHeight: 36)
	}
}

private struct CenteredMicrophoneProgressStyle: ProgressViewStyle {
	func makeBody(configuration: Configuration) -> some View {
		VStack(spacing: 6) {
			configuration.label
				.font(.subheadline)
				.multilineTextAlignment(.center)
				.frame(maxWidth: .infinity)
			GeometryReader { geometry in
				ZStack {
					Capsule().fill(.quaternary)
					Capsule()
						.fill(.tint)
						.frame(width: geometry.size.width * (configuration.fractionCompleted ?? 0))
				}
			}
			.frame(height: 4)
		}
	}
}

struct StatusCard: View {
	let state: GameState

	@ViewBuilder
	var body: some View {
		Group {
			switch state {
			case .waitingForPlayer:
				Text("Your turn. Speak a move or say a command.")
			case .recoveringAudio:
				Text("Resetting microphone…")
			case .requestingPermission:
				Text("Checking microphone and speech access…")
			case .listening:
				Text("Listening…")
					.foregroundColor(.red)
			case .finishingRecognition:
				Text("Finishing transcription…")
			case .processingPlayerMove(let move):
				Text("Parsed: \(move)")
			case .thinking:
				Text("Thinking…")
					.foregroundColor(.orange)
			case .moveRejected(let reason):
				Text(reason)
					.foregroundColor(.red)
			case .speakingResponse(let text):
				Text(text)
					.foregroundColor(.blue)
			case .gameOver(let result):
				Text("Game Over: \(result)")
			}
		}
		.multilineTextAlignment(.center)
		.lineLimit(3)
		.frame(maxWidth: .infinity)
		.frame(height: 72)
	}
}
