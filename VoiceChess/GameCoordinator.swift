import Foundation
import Combine
import ChessKit

enum PlayerColorChoice: String, Codable {
	case white = "White"
	case black = "Black"
	case random = "Random"

	var pieceColor: Piece.Color? {
		switch self {
		case .white: .white
		case .black: .black
		case .random: nil
		}
	}
}

enum GameChoice: String, CaseIterable, Identifiable, Codable {
	case white = "White"
	case black = "Black"
	case random = "Random"
	case puzzle = "Puzzle"
	var id: String { rawValue }
}

enum PuzzleMateChoice: String, CaseIterable, Identifiable, Codable {
	case one = "Mate in 1"
	case two = "Mate in 2"
	case three = "Mate in 3"
	var id: String { rawValue }
	var mateCount: Int {
		switch self {
		case .one: 1
		case .two: 2
		case .three: 3
		}
	}
}

private enum GameSetupStage {
	case color
	case difficulty
	case puzzleMate
	case confirmation
}

private enum BoardReadPurpose {
	case callout
	case puzzle
}

private enum SessionConfirmation {
	case restart
	case revert(toMove: Int)

	var prompt: String {
		switch self {
		case .restart:
			"Start a new game and end this session? Say yes or no."
		case .revert(let number):
			"Revert to move \(number) and discard the later moves? Say yes or no."
		}
	}
}

private enum MoveAuthor: String {
	case player = "Player"
	case computer = "AI"
	case opponent = "Opponent"
	case opening = "Position"

	var spokenPrefix: String {
		switch self {
		case .player: "You played"
		case .computer: "I played"
		case .opponent: "The opponent played"
		case .opening: "The opening move was"
		}
	}
}

enum GameState {
	case waitingForPlayer
	case requestingPermission
	case recoveringAudio
	case listening
	case finishingRecognition
	case processingPlayerMove(String)
	case moveRejected(reason: String)
	case thinking
	case speakingResponse(String)
	case gameOver(String)
}

final class GameCoordinator: ObservableObject {
	@Published var currentState: GameState = .waitingForPlayer
	@Published var moveHistory: [String] = []
	@Published private(set) var gameStarted = false
	@Published var selectedGameChoice: GameChoice = .white
	@Published var selectedDifficulty: ChessDifficulty = .one
	@Published var selectedPuzzleMate: PuzzleMateChoice = .one
	@Published private(set) var setupMessage = ""
	private var setupListeningStarted = false
	private var setupStage: GameSetupStage = .color
	private var setupColorChosen = false
	private var setupDifficultyChosen = false
	private var pendingSessionConfirmation: SessionConfirmation?
	private var playerColor: PlayerColorChoice = .white
	@Published private(set) var lastComputerAnnouncement: String?
	private var lastMoveAnnouncement: String?
	
	@Published var transcript = ""
	private var alternativeTranscripts: [String] = []
	private enum MoveQuestion {
		case confirm(String)
		case origin([String])
	}
	private var moveQuestion: MoveQuestion?
	@Published private(set) var inputLevel: Float = 0
	private var peakDecibels: Float?
	var microphoneName: String { speechManager.microphoneName }

	private func unheardMoveMessage(_ error: Error? = nil) -> String {
		let microphoneName = self.microphoneName
		if peakDecibels == nil || (peakDecibels ?? 0) <= -119 {
			speechManager.resetCapture()
		}
		let cause = error as NSError?
		if let cause, !(cause.domain == "kAFAssistantErrorDomain" && cause.code == 1110) {
			return cause.localizedDescription
		}
		guard let peakDecibels else { return "No microphone samples received from \(microphoneName). Check the audio input and try again." }
		if peakDecibels <= -119 {
			return "\(microphoneName) delivered silent audio. Check the microphone with Voice Memos."
		}
		if peakDecibels < -55 {
			return "Low input from \(microphoneName) (\(Int(peakDecibels.rounded())) dBFS). Compare with a Voice Memos recording."
		}
		return "\(microphoneName) picked up sound, but no words were recognized. Try saying “pawn to E four.”"
	}

	private var permissionTask: Task<Void, Never>?
	private var recognitionTimeout: Task<Void, Never>?
	private var pauseTask: Task<Void, Never>?
	private var transcriptStabilityTask: Task<Void, Never>?
	private var stableTranscriptCandidate: String?
	private var speechDetected = false
	private var latestDecibels: Float = -120
	private var ambientNoiseSamples: [Float] = []
	private var ambientNoiseLevel: Float = -60
	private var hasAmbientNoiseEstimate = false
	private var listeningStartedAt = Date.distantPast
	private var initialSquareFileHint: String?
	private var shouldResumeListeningAfterBackground = false
	private var startGameAfterColorAnnouncement = false
	private var pendingDangerAnnouncement: String?
	private var boardReadRows: [String] = []
	private var boardReadIndex = 0
	private var boardReadActive = false
	private var boardCommandReminderPending = false
	private var boardReadPurpose: BoardReadPurpose?
	private var boardReadMateCount: Int?
	private var boardReadAfterPuzzleRestore = false
	private var puzzleSelectionPending = false
	private var puzzleModeActive = false
	private var activePuzzle: ChessPuzzle?
	private var puzzleSolutionIndex = 1
	private var puzzleSolved = false
	private var usedPuzzleIDs: Set<String> = []
	private var completedPuzzleIDs = GameSessionStore.shared.completedPuzzleIDs
	private let sessionStore = GameSessionStore.shared
	private var startupRestoreChecked = false
	private var resumeAITurnAfterAnnouncement = false
	private let speechManager = SpeechRecognizerManager()
	let synthesizer = VoiceSynthesizer()
	let engine = ChessEngineManager()
	private let stockfish = StockfishEngineManager()
	private let maia = MaiaCoreMLEngineManager()
	
	init() {
		synthesizer.onSpeechFinished = { [weak self] in
			DispatchQueue.main.async {
				self?.handleSpeechFinished()
			}
		}
	}

	func startNewGame() {
		guard !gameStarted else { return }
		if selectedGameChoice == .puzzle {
			startPuzzleMode(mateIn: selectedPuzzleMate.mateCount)
			return
		}
		clearPuzzleMode()
		let choseRandomColor = selectedGameChoice == .random
		startGameAfterColorAnnouncement = false
		speechManager.stopListening()
		setupListeningStarted = false
		setupColorChosen = true
		setupDifficultyChosen = true
		gameStarted = true
		if choseRandomColor {
			playerColor = Bool.random() ? .white : .black
		} else {
			playerColor = selectedGameChoice == .black ? .black : .white
		}
		engine.resetGame()
		moveHistory = []
		transcript = ""
		lastComputerAnnouncement = nil
		lastMoveAnnouncement = nil
		pendingDangerAnnouncement = nil
		persistCheckpoint()
		if playerColor == .white {
			if choseRandomColor {
				announceRandomlyChosenColor()
			} else {
				startPlayerTurn()
			}
		} else {
			if choseRandomColor {
				announceRandomlyChosenColor()
			} else {
				processAITurn(playerSan: nil)
			}
		}
	}

	private func announceRandomlyChosenColor() {
		let message = playerColor == .white
			? "You are playing White."
			: "You are playing Black. I will move first."
		startGameAfterColorAnnouncement = true
		lastComputerAnnouncement = message
		currentState = .speakingResponse(message)
		synthesizer.speak(message)
	}

	func requestGameStartConfirmation() {
		setupColorChosen = true
		setupDifficultyChosen = true
		askForGameConfirmation()
	}

	func beginVoiceSetup() {
		guard !gameStarted, !setupListeningStarted else { return }
		setupListeningStarted = true
		if !startupRestoreChecked {
			startupRestoreChecked = true
			if let snapshot = sessionStore.loadCheckpoint() {
				if restore(snapshot) { return }
				sessionStore.clearCheckpoint()
			}
		}
		askForSetupColor()
	}

	private func askForSetupColor() {
		setupStage = .color
		setupMessage = "Which game would you like: white, black, random, or puzzle?"
		currentState = .speakingResponse(setupMessage)
		synthesizer.speak(setupMessage)
	}

	private func askForSessionConfirmation(_ confirmation: SessionConfirmation) {
		pendingSessionConfirmation = confirmation
		let message = confirmation.prompt
		currentState = .speakingResponse(message)
		synthesizer.speak(message)
	}

	private func handleSessionConfirmation(_ confirmation: SessionConfirmation, reply text: String) {
		switch normalizedCommand(text) {
		case "yes", "yeah", "yep":
			pendingSessionConfirmation = nil
			switch confirmation {
			case .restart: beginNewGameSetup()
			case .revert(let number): revertToMove(number)
			}
		case "no", "nope", "cancel":
			pendingSessionConfirmation = nil
			if boardReadActive {
				speakBoardReadRow()
			} else {
				startPlayerTurn()
			}
		default:
			askForSessionConfirmation(confirmation)
		}
	}

	private func beginNewGameSetup() {
		pendingSessionConfirmation = nil
		resumeAITurnAfterAnnouncement = false
		speechManager.stopListening()
		permissionTask?.cancel()
		recognitionTimeout?.cancel()
		pauseTask?.cancel()
		transcriptStabilityTask?.cancel()
		transcriptStabilityTask = nil
		stableTranscriptCandidate = nil
		synthesizer.stopSpeaking()
		clearPuzzleMode()
		sessionStore.clearCheckpoint()
		startGameAfterColorAnnouncement = false
		gameStarted = false
		setupListeningStarted = true
		setupColorChosen = false
		setupDifficultyChosen = false
		selectedGameChoice = .white
		selectedDifficulty = .one
		selectedPuzzleMate = .one
		engine.resetGame()
		moveHistory = []
		lastComputerAnnouncement = nil
		lastMoveAnnouncement = nil
		pendingDangerAnnouncement = nil
		transcript = ""
		askForSetupColor()
	}
	
	func startPlayerTurn() {
		guard canStart else { return }
		synthesizer.stopSpeaking()
		transcriptStabilityTask?.cancel()
		transcriptStabilityTask = nil
		stableTranscriptCandidate = nil
		inputLevel = 0
		peakDecibels = nil
		speechDetected = false
		latestDecibels = -120
		ambientNoiseSamples = []
		ambientNoiseLevel = -60
		hasAmbientNoiseEstimate = false
		initialSquareFileHint = nil
		alternativeTranscripts = []
		currentState = .requestingPermission
		transcript = ""
		permissionTask = Task { @MainActor [self] in
			let granted = await speechManager.requestPermissions()
			guard !Task.isCancelled else { return }
			guard granted else {
				currentState = .moveRejected(reason: "Allow microphone and speech recognition access in Settings to speak a move.")
				return
			}
			do {
				listeningStartedAt = Date()
				try await speechManager.startListening(contextualStrings: engine.speechContextualStrings, onLevel: { [weak self] decibels in
					guard let self else { return }
					peakDecibels = max(peakDecibels ?? decibels, decibels)
					inputLevel = min(1, max(0, (decibels + 60) / 60))
					latestDecibels = decibels
					if case .listening = currentState {
						updateAmbientNoiseEstimate(decibels)
						let noiseLevel = hasAmbientNoiseEstimate ? ambientNoiseLevel : -55
						if !speechDetected, decibels > noiseLevel + 9 {
							speechDetected = true
						}
						if speechDetected, !transcript.isEmpty {
							if decibels <= noiseLevel + 5 {
								if pauseTask == nil { scheduleMoveAfterPause() }
							} else {
							pauseTask?.cancel()
							pauseTask = nil
						}
						}
					}
				}) { [weak self] readings, finished, error in
					guard let self else { return }
					if let text = readings.first, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
						let updatedTranscript = preservingInitialSquareFile(in: text)
						alternativeTranscripts = readings.filter { $0 != updatedTranscript }
						let transcriptChanged = updatedTranscript != transcript
						transcript = updatedTranscript
						if case .listening = currentState, !speechDetected {
							speechDetected = true
						}
						if case .listening = currentState {
							recognitionTimeout?.cancel()
							if transcriptChanged {
								scheduleStableMoveSubmission(for: updatedTranscript)
							}
							let noiseLevel = hasAmbientNoiseEstimate ? ambientNoiseLevel : -55
							if speechDetected, latestDecibels <= noiseLevel + 5, pauseTask == nil {
								scheduleMoveAfterPause()
							}
						}
					}
					if finished {
						if transcript.isEmpty, case .listening = currentState {
							currentState = .moveRejected(reason: unheardMoveMessage(error))
							Task { @MainActor [weak self] in
								try? await Task.sleep(for: .milliseconds(250))
								guard let self, case .moveRejected = currentState else { return }
								startPlayerTurn()
							}
							return
						}
						recognitionTimeout?.cancel()
						finishRecognizedMove(error: error)
					}
				}
				currentState = .listening
				synthesizer.playListeningBeep()
				scheduleRecognitionTimeout(seconds: 10)
			} catch is CancellationError {
				return
			} catch {
				currentState = .moveRejected(reason: error.localizedDescription)
			}
		}
	}

	private func updateAmbientNoiseEstimate(_ decibels: Float) {
		guard transcript.isEmpty, Date().timeIntervalSince(listeningStartedAt) >= 0.18 else { return }
		ambientNoiseSamples.append(decibels)
		if ambientNoiseSamples.count > 24 {
			ambientNoiseSamples.removeFirst(ambientNoiseSamples.count - 24)
		}
		let orderedLevels = ambientNoiseSamples.sorted()
		let lowerQuartileIndex = Int(Float(orderedLevels.count - 1) * 0.25)
		let estimate = orderedLevels[lowerQuartileIndex]
		if hasAmbientNoiseEstimate {
			ambientNoiseLevel += (estimate - ambientNoiseLevel) * 0.25
		} else {
			ambientNoiseLevel = estimate
			hasAmbientNoiseEstimate = true
		}
	}

	private func preservingInitialSquareFile(in text: String) -> String {
		let words = text.lowercased()
			.components(separatedBy: CharacterSet.alphanumerics.inverted)
			.filter { !$0.isEmpty }
		if initialSquareFileHint == nil, words.count == 1,
		   let file = MoveParser.fileWords[words[0]] {
			initialSquareFileHint = file
		}
		guard let initialSquareFileHint, words.count <= 2 else { return text }
		let parsed = MoveParser.parseSan(from: text).lowercased()
		guard parsed.count == 2,
			  "abcdefgh".contains(parsed.first!),
			  "12345678".contains(parsed.last!),
			  parsed.first != initialSquareFileHint.first else { return text }
		return "\(initialSquareFileHint)\(parsed.last!)"
	}

	func recoverAudio() {
		guard case .recoveringAudio = currentState else {
			currentState = .recoveringAudio
			permissionTask?.cancel()
			recognitionTimeout?.cancel()
			transcriptStabilityTask?.cancel()
			transcriptStabilityTask = nil
			stableTranscriptCandidate = nil
			speechManager.resetCapture()
			synthesizer.stopSpeaking()
			Task { @MainActor [weak self] in
				try? await Task.sleep(for: .milliseconds(800))
				guard let self, case .recoveringAudio = currentState else { return }
				do {
					try await speechManager.startListening(contextualStrings: engine.speechContextualStrings, onLevel: { [weak self] level in
						guard let self else { return }
						inputLevel = min(1, max(0, (level + 60) / 60))
					}) { [weak self] _, finished, error in
						guard finished, let self else { return }
						speechManager.stopListening()
						currentState = .waitingForPlayer
						if let error { print("Audio recovery probe: \(error.localizedDescription)") }
					}
					currentState = .listening
					try? await Task.sleep(for: .milliseconds(600))
					speechManager.stopListening()
					currentState = .waitingForPlayer
				} catch is CancellationError {
					return
				} catch {
					speechManager.resetCapture()
					currentState = .moveRejected(reason: "Audio recovery failed: \(error.localizedDescription)")
				}
			}
			return
		}
	}

	var canCancelRecording: Bool {
		switch currentState {
		case .listening, .finishingRecognition: return true
		default: return false
		}
	}

	func stopForBackground() {
		moveQuestion = nil
		persistCheckpoint()
		switch currentState {
		case .requestingPermission, .recoveringAudio, .listening, .finishingRecognition,
			 .speakingResponse, .moveRejected, .gameOver:
			shouldResumeListeningAfterBackground = true
		default:
			shouldResumeListeningAfterBackground = false
		}
		permissionTask?.cancel()
		recognitionTimeout?.cancel()
		pauseTask?.cancel()
		pauseTask = nil
		transcriptStabilityTask?.cancel()
		transcriptStabilityTask = nil
		stableTranscriptCandidate = nil
		speechManager.stopListening()
		synthesizer.stopSpeaking()
		switch currentState {
		case .requestingPermission, .recoveringAudio, .listening, .finishingRecognition,
			 .speakingResponse, .moveRejected, .gameOver:
			currentState = .waitingForPlayer
			transcript = ""
		default: break
		}
	}

	func resumeAfterForeground() {
		guard shouldResumeListeningAfterBackground else { return }
		shouldResumeListeningAfterBackground = false
		guard case .waitingForPlayer = currentState else { return }
		if let confirmation = pendingSessionConfirmation {
			askForSessionConfirmation(confirmation)
			return
		}
		if startGameAfterColorAnnouncement || resumeAITurnAfterAnnouncement,
		   let announcement = lastComputerAnnouncement {
			currentState = .speakingResponse(announcement)
			synthesizer.speak(announcement)
			return
		}
		startPlayerTurn()
	}

	func cancelRecording() {
		guard canCancelRecording else { return }
		moveQuestion = nil
		recognitionTimeout?.cancel()
		transcriptStabilityTask?.cancel()
		transcriptStabilityTask = nil
		stableTranscriptCandidate = nil
		speechManager.stopListening()
		transcript = ""
		currentState = .waitingForPlayer
	}

	func finishRecording() {
		guard case .listening = currentState else { return }
		transcriptStabilityTask?.cancel()
		transcriptStabilityTask = nil
		stableTranscriptCandidate = nil
		currentState = .finishingRecognition
		speechManager.finishAudio()
		scheduleRecognitionTimeout(seconds: 4)
	}

	private func scheduleRecognitionTimeout(seconds: Int) {
		recognitionTimeout?.cancel()
		recognitionTimeout = Task { @MainActor [weak self] in
			do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
			guard let self else { return }
			switch currentState {
			case .listening:
				finishRecording()
			case .finishingRecognition:
				speechManager.stopListening()
				finishRecognizedMove(error: nil)
			default: break
			}
		}
	}

	private func finishRecognizedMove(error: Error?) {
		let wasFinishing: Bool
		if case .finishingRecognition = currentState { wasFinishing = true } else { wasFinishing = false }
		switch currentState {
		case .finishingRecognition, .listening: break
		default: return
		}
		recognitionTimeout?.cancel()
		if transcript.isEmpty {
			let message = unheardMoveMessage(error)
			currentState = .moveRejected(reason: message)
			if wasFinishing {
				Task { @MainActor [weak self] in
					try? await Task.sleep(for: .milliseconds(250))
					guard let self, case .moveRejected = currentState else { return }
					startPlayerTurn()
				}
			}
			return
		}
		currentState = .processingPlayerMove(MoveParser.parseSan(from: transcript))
		confirmPlayerMove()
	}

	private var stateIsAwaitingFinalTranscript: Bool {
		if case .listening = currentState { return true }
		return false
	}

	private func scheduleMoveAfterPause() {
		pauseTask = Task { @MainActor [weak self] in
			do {
				try await Task.sleep(for: .milliseconds(1500))
			} catch {
				return
			}
			guard let self, speechDetected, !transcript.isEmpty,
				  case .listening = currentState else {
				self?.pauseTask = nil
				return
			}
			pauseTask = nil
			finishRecording()
		}
	}

	private func scheduleStableMoveSubmission(for text: String) {
		transcriptStabilityTask?.cancel()
		transcriptStabilityTask = nil
		stableTranscriptCandidate = nil
		guard isStableSubmissionCandidate(text) else { return }
		stableTranscriptCandidate = text
		transcriptStabilityTask = Task { @MainActor [weak self] in
			do {
				try await Task.sleep(for: .milliseconds(900))
			} catch {
				return
			}
			guard let self, case .listening = currentState,
				  transcript == text, stableTranscriptCandidate == text,
				  isStableSubmissionCandidate(transcript) else { return }
			transcriptStabilityTask = nil
			stableTranscriptCandidate = nil
			pauseTask?.cancel()
			pauseTask = nil
			finishRecording()
		}
	}

	private func isStableSubmissionCandidate(_ text: String) -> Bool {
		if pendingSessionConfirmation != nil {
			return ["yes", "yeah", "yep", "no", "nope", "cancel"].contains(normalizedCommand(text))
		}
		if isActionableVoiceCommand(text) { return true }
		guard gameStarted, !puzzleSelectionPending, !boardReadActive else { return false }
		guard let san = MoveParser.completeLegacySAN(text) else { return false }
		return engine.isLegalPlayerMove(san)
	}

	private func isActionableVoiceCommand(_ text: String) -> Bool {
		if isHelpCommand(text) || isNewGameCommand(text)
			|| isCancelPuzzleCommand(text) || isPuzzleStartCommand(text)
			|| isRepeatCommand(text) || isHintCommand(text) || isBoardCalloutCommand(text)
			|| isMoveHistoryCalloutCommand(text) || isUndoCommand(text)
			|| pieceLocationWords(text).map({ $0.count >= 2 }) == true
			|| rankCalloutArgument(text).map({ !$0.isEmpty }) == true
			|| revertMoveArgument(text).map({ !$0.isEmpty }) == true {
			return true
		}
		let phrase = normalizedCommand(text)
		if boardReadActive {
			return ["continue", "next", "okay", "ok", "repeat", "repeat that", "say again", "cancel", "stop", "cancel board"].contains(phrase)
		}
		if puzzleModeActive, isNextPuzzleCommand(text) { return true }
		let words = Set(phrase.split(separator: " ").map(String.init))
		if puzzleSelectionPending {
			return !words.isDisjoint(with: ["one", "won", "1", "single", "two", "to", "too", "2", "three", "3"])
		}
		guard !gameStarted else { return false }
		switch setupStage {
		case .color:
			return !words.isDisjoint(with: ["white", "black", "random", "puzzle"])
		case .difficulty:
			return parseDifficulty(from: words) != nil
		case .puzzleMate:
			return !words.isDisjoint(with: ["one", "won", "1", "single", "two", "to", "too", "2", "three", "3"])
		case .confirmation:
			return !words.isDisjoint(with: ["yes", "yeah", "yep", "correct", "start", "no", "nope"])
		}
	}

	var canStart: Bool {
		switch currentState {
		case .waitingForPlayer, .moveRejected, .processingPlayerMove, .speakingResponse: return true
		default: return false
		}
	}

	var canConfirm: Bool {
		switch currentState {
		case .listening, .processingPlayerMove: return !transcript.isEmpty
		default: return false
		}
	}

	func confirmPlayerMove() {
		guard canConfirm else { return }
		recognitionTimeout?.cancel()
		pauseTask?.cancel()
		transcriptStabilityTask?.cancel()
		transcriptStabilityTask = nil
		stableTranscriptCandidate = nil
		let rawText = transcript
		let question = moveQuestion
		moveQuestion = nil
		currentState = .processingPlayerMove(rawText)
		speechManager.stopListening()
		if let confirmation = pendingSessionConfirmation {
			handleSessionConfirmation(confirmation, reply: rawText)
			return
		}
		if isOverlongUtterance(rawText) {
			transcript = ""
			startPlayerTurn()
			return
		}
		if isHelpCommand(rawText) {
			announceHelp()
			return
		}
		if isNewGameCommand(rawText) {
			if gameStarted {
				askForSessionConfirmation(.restart)
			} else {
				beginNewGameSetup()
			}
			return
		}
		if isCancelPuzzleCommand(rawText) {
			if gameStarted && !puzzleModeActive {
				announce("There is no puzzle in progress.")
			} else {
				beginNewGameSetup()
			}
			return
		}
		if isPuzzleStartCommand(rawText), standardGameInProgress {
			announce("A game is in progress. Say new game and confirm to choose puzzle mode.")
			return
		}
		if isMoveHistoryCalloutCommand(rawText) {
			callOutMoves()
			return
		}
		if let words = pieceLocationWords(rawText) {
			announcePieceLocations(words)
			return
		}
		if let argument = rankCalloutArgument(rawText) {
			callOutRank(argument)
			return
		}
		if let argument = revertMoveArgument(rawText) {
			requestRevert(to: argument)
			return
		}
		if boardReadActive {
			handleBoardReadCommand(rawText)
			return
		}
		if isPuzzleStartCommand(rawText) {
			if !gameStarted {
				processVoiceSetupCommand(rawText)
				return
			}
			let phrase = normalizedCommand(rawText)
			if phrase == "mate in one" { startPuzzleMode(mateIn: 1) }
			else if phrase == "mate in two" { startPuzzleMode(mateIn: 2) }
			else if phrase == "mate in three" { startPuzzleMode(mateIn: 3) }
			else { startPuzzleMode(mateIn: nil) }
			return
		}
		if puzzleSelectionPending {
			selectPuzzleDifficulty(from: rawText)
			return
		}
		if !gameStarted {
			processVoiceSetupCommand(rawText)
			return
		}
		if isRepeatCommand(rawText) {
			repeatLastMoveAnnouncement()
			return
		}
		if isHintCommand(rawText) {
			requestHint()
			return
		}
		if isBoardCalloutCommand(rawText) {
			callOutBoard()
			return
		}
		if isUndoCommand(rawText) {
			undoLastTurn()
			return
		}
		if puzzleModeActive {
			if isNextPuzzleCommand(rawText), let mateIn = activePuzzleMateCount {
				loadNextPuzzle(mateIn: mateIn)
				return
			}
			if puzzleSolved {
				let message = "Say next puzzle for another one, or cancel puzzle to leave puzzle mode."
				lastComputerAnnouncement = message
				currentState = .speakingResponse(message)
				synthesizer.speak(message)
				return
			}
		}
		if let question {
			let reply = normalizedCommand(rawText)
			if ["no", "nope", "cancel"].contains(reply) { startPlayerTurn(); return }
			let selected: String?
			switch question {
			case .confirm(let uci):
				selected = ["yes", "yeah", "yep", "correct"].contains(reply) ? uci : nil
			case .origin(let moves):
				let square = MoveParser.completeLegacySAN(reply)
				selected = moves.first { String($0.prefix(2)) == square }
			}
			if let selected, let san = engine.sanForUCIMove(selected) {
				playSpokenMove(san, rawText: rawText)
				return
			}
			// A full replacement move can be spoken instead of answering yes or no.
		}
		switch engine.matchSpokenMove([rawText] + alternativeTranscripts) {
		case .play(let san):
			playSpokenMove(san, rawText: rawText)
		case .confirm(let uci, let phrase):
			askMoveQuestion(.confirm(uci), "\(phrase)?")
		case .chooseOrigin(let moves, let piece):
			askMoveQuestion(.origin(moves), "Which \(piece.lowercased())?")
		case .illegal(let san):
			rejectSpokenMove(san, rawText: rawText)
		case .unheard:
			retryListeningAfterInvalidMove()
		}
	}

	private func askMoveQuestion(_ question: MoveQuestion, _ prompt: String) {
		moveQuestion = question
		currentState = .speakingResponse(prompt)
		synthesizer.speak(prompt)
	}

	private func playSpokenMove(_ san: String, rawText: String) {
		if puzzleModeActive {
			processPuzzleMove(san: san)
		} else if engine.makePlayerMove(san) {
			moveHistory.append("Player: \(san)")
			persistCheckpoint()
			if !finishGameIfNeeded() { processAITurn(playerSan: san) }
		} else {
			rejectSpokenMove(san, rawText: rawText)
		}
	}

	private func rejectSpokenMove(_ san: String, rawText: String) {
		let interpreted = san.hasPrefix("x") ? "a pawn capture on \(san.dropFirst())" : engine.spokenRepresentation(for: san)
		let message = engine.illegalMoveExplanation(for: san).map { "I heard \(rawText). \($0) Try again." }
			?? "I heard \(rawText) as \(interpreted), but that move isn't legal here. Try again."
		currentState = .moveRejected(reason: message)
		synthesizer.speak(message)
	}

	private func isHelpCommand(_ text: String) -> Bool {
		let words = text.lowercased()
			.components(separatedBy: CharacterSet.alphanumerics.inverted)
			.filter { !$0.isEmpty }
		return ["help", "commands", "list commands", "what can i say", "what are the commands"]
			.contains(words.joined(separator: " "))
	}

	private func isOverlongUtterance(_ text: String) -> Bool {
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		let wordCount = trimmed.components(separatedBy: .whitespacesAndNewlines)
			.filter { !$0.isEmpty }.count
		return wordCount > 14 || trimmed.count > 100
	}

	private func announceHelp() {
		let message: String
		if gameStarted {
			message = "Say a chess move such as Pawn to E Four.  Other commands: Hint. Repeat. Undo. Call out the board. Call out rank four. Call out moves. Revert to move 3. Or new game. To locate a piece, ask where is the white queen, or where are the black bishops."
		} else {
			message = "Say white, black, random, or puzzle for the game choice. For a puzzle, choose mate in one, two, or three. Game difficulties are 1 to 8 (Maia ELO 600 to 2000) 9 to 11 (Stockfish ELO 2200 to 3000) 12 (Stockfish full strength)"
		}
		lastComputerAnnouncement = message
		currentState = .speakingResponse(message)
		synthesizer.speak(message)
	}

	private func isNewGameCommand(_ text: String) -> Bool {
		let words = text.lowercased()
			.components(separatedBy: CharacterSet.alphanumerics.inverted)
			.filter { !$0.isEmpty }
		let phrase = words.joined(separator: " ")
		return ["new game", "start new game", "start a new game", "restart", "restart game", "new chess game"].contains(phrase)
	}

	private func announce(_ message: String, readout: String? = nil) {
		lastComputerAnnouncement = message
		currentState = .speakingResponse(message)
		if let readout {
			synthesizer.speakReadout(readout)
		} else {
			synthesizer.speak(message)
		}
	}

	private func makeSavedGameSnapshot() -> SavedGameSnapshot? {
		guard gameStarted else { return nil }
		let gameOverMessage: String?
		if case .gameOver(let message) = currentState { gameOverMessage = message }
		else { gameOverMessage = nil }
		return SavedGameSnapshot(
			mode: puzzleModeActive ? .puzzle : .standard,
			positionFEN: engine.board.position.fen,
			undoPositionFENs: engine.undoPositionFENs,
			selectedGameChoice: selectedGameChoice,
			playerColor: playerColor,
			difficulty: selectedDifficulty,
			moveHistory: moveHistory,
			lastComputerAnnouncement: lastComputerAnnouncement,
			lastMoveAnnouncement: lastMoveAnnouncement,
			puzzleID: activePuzzle?.id,
			puzzleSolutionIndex: puzzleSolutionIndex,
			puzzleSolved: puzzleSolved,
			usedPuzzleIDs: Array(usedPuzzleIDs),
			completedPuzzleIDs: Array(completedPuzzleIDs),
			gameOverMessage: gameOverMessage
		)
	}

	@discardableResult
	private func restore(_ snapshot: SavedGameSnapshot) -> Bool {
		let puzzle: ChessPuzzle?
		if snapshot.mode == .puzzle, let puzzleID = snapshot.puzzleID {
			puzzle = PuzzleLibrary.puzzle(id: puzzleID)
		} else {
			puzzle = nil
		}
		guard snapshot.mode == .standard || puzzle != nil,
			  engine.loadPosition(fen: snapshot.positionFEN, undoPositionFENs: snapshot.undoPositionFENs),
			  !snapshot.isFinished, !hasFinishedPosition else { return false }
		speechManager.stopListening()
		permissionTask?.cancel()
		recognitionTimeout?.cancel()
		pauseTask?.cancel()
		synthesizer.stopSpeaking()
		gameStarted = true
		selectedGameChoice = snapshot.mode == .puzzle ? .puzzle : snapshot.selectedGameChoice
		selectedDifficulty = snapshot.difficulty
		playerColor = snapshot.playerColor
		moveHistory = snapshot.moveHistory
		lastComputerAnnouncement = snapshot.lastComputerAnnouncement
		lastMoveAnnouncement = snapshot.lastMoveAnnouncement
		startGameAfterColorAnnouncement = false
		activePuzzle = puzzle
		puzzleModeActive = snapshot.mode == .puzzle
		puzzleSelectionPending = false
		puzzleSolutionIndex = snapshot.puzzleSolutionIndex
		puzzleSolved = snapshot.puzzleSolved
		usedPuzzleIDs = Set(snapshot.usedPuzzleIDs)
		completedPuzzleIDs.formUnion(snapshot.completedPuzzleIDs)
		completedPuzzleIDs.formUnion(sessionStore.completedPuzzleIDs)
		sessionStore.saveCompletedPuzzleIDs(completedPuzzleIDs)
		boardReadRows = []
		boardReadActive = false
		boardReadAfterPuzzleRestore = snapshot.mode == .puzzle
		pendingDangerAnnouncement = nil
		transcript = ""
		let playerSide: Piece.Color = playerColor == .white ? .white : .black
		resumeAITurnAfterAnnouncement = snapshot.mode == .standard
			&& engine.board.position.sideToMove != playerSide
		let restoredMessage: String
		if let gameOverMessage = snapshot.gameOverMessage {
			restoredMessage = gameOverMessage
		} else if snapshot.mode == .puzzle {
			let progress = puzzleSolved ? " You solved it." : ""
			restoredMessage = "Puzzle restored.\(progress)"
		} else {
			restoredMessage = "Saved game restored."
		}
		lastComputerAnnouncement = restoredMessage
		currentState = snapshot.gameOverMessage.map(GameState.gameOver) ?? .speakingResponse(restoredMessage)
		synthesizer.speak(restoredMessage)
		sessionStore.saveCheckpoint(snapshot)
		return true
	}

	private func persistCheckpoint() {
		guard !isFinishedSession else {
			sessionStore.clearCheckpoint()
			return
		}
		guard let snapshot = makeSavedGameSnapshot() else { return }
		sessionStore.saveCheckpoint(snapshot)
	}

	private var isFinishedSession: Bool {
		if puzzleSolved || hasFinishedPosition { return true }
		if case .gameOver = currentState { return true }
		return false
	}

	private var standardGameInProgress: Bool {
		gameStarted && !puzzleModeActive && !hasFinishedPosition
	}

	private var hasFinishedPosition: Bool {
		if case .checkmate = engine.board.state { return true }
		if case .draw = engine.board.state { return true }
		return false
	}

	private func isBoardCalloutCommand(_ text: String) -> Bool {
		let words = text.lowercased()
			.components(separatedBy: CharacterSet.alphanumerics.inverted)
			.filter { !$0.isEmpty }
		let phrase = words.joined(separator: " ")
		return ["call out the board", "call out board", "callout the board", "describe the board", "read the board", "board position"].contains(phrase)
	}

	private func isMoveHistoryCalloutCommand(_ text: String) -> Bool {
		["call out moves", "call out the moves", "callout moves", "read moves", "read the moves", "read move history"]
			.contains(normalizedCommand(text))
	}

	private func isUndoCommand(_ text: String) -> Bool {
		let words = text.lowercased()
			.components(separatedBy: CharacterSet.alphanumerics.inverted)
			.filter { !$0.isEmpty }
		return ["undo", "undo that", "take back", "takeback", "take that back"].contains(words.joined(separator: " "))
	}

	private func undoLastTurn() {
		let lastMoves = Array(moveHistory.suffix(2))
		guard engine.canUndoLastTurn,
			  lastMoves.count == 2,
			  lastMoves[0].hasPrefix("Player:"),
			  lastMoves[1].hasPrefix("AI:") else {
			let message = "There isn't a complete turn to undo yet."
			currentState = .speakingResponse(message)
			lastComputerAnnouncement = message
			synthesizer.speak(message)
			return
		}

		guard engine.undoLastMove(), engine.undoLastMove() else { return }
		moveHistory.removeLast(2)
		persistCheckpoint()
		let message = "Undone. Your move again."
		lastComputerAnnouncement = message
		currentState = .speakingResponse(message)
		synthesizer.speak(message)
	}

	private func callOutBoard() {
		beginBoardRead(purpose: .callout, mateIn: nil)
	}

	private func rankCalloutArgument(_ text: String) -> String? {
		let words = text.lowercased().split(whereSeparator: \.isWhitespace)
		guard words.prefix(3).elementsEqual(["call", "out", "rank"]) else { return nil }
		return words.dropFirst(3).joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ".,!?"))
	}

	private func callOutRank(_ argument: String) {
		guard gameStarted, !puzzleSelectionPending else {
			announce("Start a game or puzzle to call out a rank.")
			return
		}
		guard let rank = spokenNumber(from: argument, through: 8), (1...8).contains(rank) else {
			announce("Say call out rank followed by a number from 1 to 8.")
			return
		}
		let message = engine.spokenBoardRow(rank: rank)
		announce(message, readout: message)
	}

	private func pieceLocationWords(_ text: String) -> ArraySlice<Substring>? {
		let words = normalizedCommand(text).split(separator: " ")
		guard words.count >= 2, words[0] == "where",
			  ["is", "are", "s", "re"].contains(words[1]) else { return nil }
		var arguments = words.dropFirst(2)
		if arguments.first == "the" { arguments = arguments.dropFirst() }
		if arguments.last == "please" { arguments = arguments.dropLast() }
		return arguments
	}

	private func pieceLocationTarget(_ words: ArraySlice<Substring>, matcher: SpokenMoveMatcher? = nil) -> (colour: Piece.Color, kind: Piece.Kind)? {
		guard words.count == 2, let colourWord = words.first, let pieceWord = words.last else { return nil }
		func colourNames(_ colour: Piece.Color) -> [String] { [colour.description.lowercased()] }
		func pieceNames(_ kind: Piece.Kind) -> [String] {
			let name = kind.description.lowercased()
			return kind == .pawn ? [name, "pawns", "paws"] : [name, name + "s"]
		}
		let colours = Piece.Color.allCases
		let pieces = Piece.Kind.allCases
		guard let colour = colours.first(where: { colourNames($0).contains(String(colourWord)) })
			?? matcher?.closestWord(to: String(colourWord), candidates: colours, spellings: colourNames),
			  let kind = pieces.first(where: { pieceNames($0).contains(String(pieceWord)) })
			?? matcher?.closestWord(to: String(pieceWord), candidates: pieces, spellings: pieceNames) else { return nil }
		return (colour, kind)
	}

	private func announcePieceLocations(_ words: ArraySlice<Substring>) {
		guard gameStarted, !puzzleSelectionPending else {
			announce("Start a game or puzzle to locate pieces.")
			return
		}
		let readings = [words] + alternativeTranscripts.compactMap(pieceLocationWords)
		let exact = readings.lazy.compactMap { self.pieceLocationTarget($0) }.first
		guard let (colour, kind) = exact ?? readings.lazy.compactMap({
			self.pieceLocationTarget($0, matcher: .shared)
		}).first else {
			announce("Name a colour and piece. For example, where are the black bishops?")
			return
		}
		let squares = engine.board.position.pieces.compactMap { piece in
			piece.color == colour && piece.kind == kind ? piece.square : nil
		}.sorted { $0.notation < $1.notation }
		let name = "\(colour.description.lowercased()) \(kind.description.lowercased())"
		guard !squares.isEmpty else {
			announce("There are no \(name)s on the board.")
			return
		}
		let leadIn = squares.count == 1 ? "The \(name) is on" : "The \(name)s are on"
		let locations = squares.map { $0.notation.uppercased() }
			.formatted(.list(type: .and).locale(Locale.current))
		let spokenLocations = squares.map { square in
			"\(square.file.rawValue.uppercased()) \(square.rank.value)"
		}.joined(separator: ", ")
		announce("\(leadIn) \(locations).", readout: "\(leadIn) \(spokenLocations).")
	}

	private var recordedMoves: [(historyIndex: Int, author: MoveAuthor, san: String)] {
		moveHistory.enumerated().compactMap { index, entry in
			let parts = entry.split(separator: ":", maxSplits: 1)
			guard parts.count == 2, let author = MoveAuthor(rawValue: String(parts[0])) else { return nil }
			let san = parts[1].trimmingCharacters(in: .whitespaces)
			guard !san.isEmpty else { return nil }
			return (index, author, san)
		}
	}

	private func callOutMoves() {
		let moves = recordedMoves.enumerated().map { index, move in
			"Move \(index + 1), \(move.author.spokenPrefix) \(engine.spokenRepresentation(for: move.san))."
		}
		guard !moves.isEmpty else {
			announce("No moves have been played yet.")
			return
		}
		currentState = .speakingResponse("Reading moves…")
		synthesizer.speakReadout(moves.joined(separator: " "))
	}

	private func revertMoveArgument(_ text: String) -> String? {
		let words = text.lowercased().split(whereSeparator: \.isWhitespace)
		guard words.prefix(3).elementsEqual(["revert", "to", "move"]) else { return nil }
		return words.dropFirst(3).joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ".,!?"))
	}

	private func spokenNumber(from argument: String, through maximum: Int) -> Int? {
		if let number = Int(argument) { return number }
		let words = normalizedCommand(argument).split(separator: " ").filter { $0 != "and" }
		guard !words.isEmpty else { return nil }
		let formatter = NumberFormatter()
		formatter.locale = Locale.current
		formatter.numberStyle = .spellOut
		return (1...maximum).first { number in
			guard let name = formatter.string(from: NSNumber(value: number)) else { return false }
			return normalizedCommand(name).split(separator: " ") == words
		}
	}

	private func requestRevert(to argument: String) {
		let moves = recordedMoves
		guard gameStarted, !moves.isEmpty else {
			announce("No moves have been played yet.")
			return
		}
		guard let number = spokenNumber(from: argument, through: moves.count), (1...moves.count).contains(number) else {
			announce("Say revert to move and a number from 1 to \(moves.count).")
			return
		}
		guard number < moves.count else {
			announce("You are already at move \(number).")
			return
		}
		askForSessionConfirmation(.revert(toMove: number))
	}

	private func revertToMove(_ number: Int) {
		let moves = recordedMoves
		guard number > 0, number < moves.count, engine.revert(toMove: number, fromMove: moves.count) else {
			announce("I couldn't restore the position after move \(number).")
			return
		}
		moveHistory.removeSubrange((moves[number - 1].historyIndex + 1)...)
		clearBoardRead()
		pendingDangerAnnouncement = nil
		lastMoveAnnouncement = moves.prefix(number).last(where: { $0.author == .computer }).map {
			"I play \(engine.spokenRepresentation(for: $0.san))."
		}
		let message = "Reverted to move \(number)."
		let opponentToMove = engine.board.position.sideToMove != playerColor.pieceColor
		if let puzzle = activePuzzle {
			puzzleSolutionIndex = number
			puzzleSolved = false
			if opponentToMove {
				playPuzzleReply(in: puzzle, after: message + " ")
				return
			}
		} else {
			resumeAITurnAfterAnnouncement = opponentToMove
		}
		announce(message)
		persistCheckpoint()
	}

	private func beginBoardRead(purpose: BoardReadPurpose, mateIn: Int?) {
		boardReadRows = engine.spokenBoardRows()
		boardReadIndex = 0
		boardReadActive = !boardReadRows.isEmpty
		boardCommandReminderPending = true
		boardReadPurpose = purpose
		boardReadMateCount = mateIn
		speakBoardReadRow()
	}

	private func speakBoardReadRow() {
		guard boardReadActive, boardReadRows.indices.contains(boardReadIndex) else { return }
		let isEmptyRank = boardReadRows[boardReadIndex].contains(" is empty.")
		let commandReminder = boardCommandReminderPending && !isEmptyRank
			? " Continue, repeat, previous, or cancel."
			: ""
		if !isEmptyRank { boardCommandReminderPending = false }
		let message = "\(boardReadRows[boardReadIndex])\(commandReminder)"
		lastComputerAnnouncement = message
		currentState = .speakingResponse(message)
		synthesizer.speakReadout(message)
	}

	private func handleBoardReadCommand(_ text: String) {
		switch normalizedCommand(text) {
		case "continue", "next", "okay", "ok":
			if boardReadIndex + 1 < boardReadRows.count {
				boardReadIndex += 1
				speakBoardReadRow()
			} else {
				finishBoardRead()
			}
		case "previous", "back":
			if boardReadIndex > 0 {
				boardReadIndex -= 1
				speakBoardReadRow()
			}
		case "repeat", "repeat that", "say again":
			speakBoardReadRow()
		case "cancel", "stop", "cancel board":
			boardReadActive = false
			boardReadRows = []
			boardCommandReminderPending = false
			boardReadPurpose = nil
			boardReadMateCount = nil
			let message = "Board reading cancelled."
			lastComputerAnnouncement = message
			currentState = .speakingResponse(message)
			synthesizer.speak(message)
		default:
			let message = "Say continue, repeat, or cancel."
			lastComputerAnnouncement = message
			currentState = .speakingResponse(message)
			synthesizer.speak(message)
		}
	}

	private func finishBoardRead() {
		boardReadActive = false
		boardReadRows = []
		boardCommandReminderPending = false
		boardReadPurpose = nil
		boardReadMateCount = nil
		let message: String
		if activePuzzle != nil, let mateCount = activePuzzleMateCount {
			let mateCountText = spokenMateCount(mateCount)
			let progress = puzzleSolved ? "You solved it." : "Your move. Find the mate."
			message = "Puzzle. You are playing \(playerColor.rawValue). Find mate in \(mateCountText). \(progress)"
		} else {
			message = "That is the full board."
		}
		lastComputerAnnouncement = message
		currentState = .speakingResponse(message)
		synthesizer.speak(message)
	}

	private func normalizedCommand(_ text: String) -> String {
		text.lowercased()
			.components(separatedBy: CharacterSet.alphanumerics.inverted)
			.filter { !$0.isEmpty }
			.joined(separator: " ")
	}

	private func isPuzzleStartCommand(_ text: String) -> Bool {
		["puzzle", "puzzle mode", "start puzzle", "start puzzles", "mate in one", "mate in two", "mate in three"]
			.contains(normalizedCommand(text))
	}

	private func isCancelPuzzleCommand(_ text: String) -> Bool {
		["cancel puzzle", "stop puzzle", "quit puzzle"].contains(normalizedCommand(text))
	}

	private func isNextPuzzleCommand(_ text: String) -> Bool {
		["next", "next puzzle", "another puzzle", "new puzzle"].contains(normalizedCommand(text))
	}

	private func startPuzzleMode(mateIn: Int?) {
		speechManager.stopListening()
		permissionTask?.cancel()
		recognitionTimeout?.cancel()
		pauseTask?.cancel()
		synthesizer.stopSpeaking()
		clearPuzzleMode()
		sessionStore.clearCheckpoint()
		pendingDangerAnnouncement = nil
		gameStarted = true
		selectedGameChoice = .puzzle
		moveHistory = []
		transcript = ""
		if let mateIn {
			selectedPuzzleMate = puzzleMateChoice(for: mateIn)
			loadNextPuzzle(mateIn: mateIn)
		} else {
			puzzleModeActive = true
			puzzleSelectionPending = true
			let message = "Puzzle mode. Would you like mate in one, two or three?"
			lastComputerAnnouncement = message
			currentState = .speakingResponse(message)
			synthesizer.speak(message)
		}
	}

	private func selectPuzzleDifficulty(from text: String) {
		let words = Set(normalizedCommand(text).split(separator: " ").map(String.init))
		if words.isDisjoint(with: ["one", "1", "single"])
			&& words.isDisjoint(with: ["two", "2"])
			&& words.isDisjoint(with: ["three", "3"]) {
			if words.contains("cancel") { beginNewGameSetup(); return }
			let message = "Please say mate in one, two or three."
			lastComputerAnnouncement = message
			currentState = .speakingResponse(message)
			synthesizer.speak(message)
			return
		}
		puzzleSelectionPending = false
		let mateIn = !words.isDisjoint(with: ["three", "3"])
			? 3
			: words.isDisjoint(with: ["one", "1", "single"]) ? 2 : 1
		selectedPuzzleMate = puzzleMateChoice(for: mateIn)
		loadNextPuzzle(mateIn: mateIn)
	}

	private func loadNextPuzzle(mateIn: Int) {
		let available = PuzzleLibrary.puzzles(mateIn: mateIn)
		guard !available.isEmpty else {
			puzzleModeActive = false
			gameStarted = false
			let message = "I couldn't load the puzzle set. Please start a new game."
			lastComputerAnnouncement = message
			currentState = .speakingResponse(message)
			synthesizer.speak(message)
			return
		}
		let incomplete = available.filter { !completedPuzzleIDs.contains($0.id) }
		var candidates = incomplete.filter { !usedPuzzleIDs.contains($0.id) }
		if candidates.isEmpty {
			usedPuzzleIDs.removeAll()
			candidates = incomplete.isEmpty ? available : incomplete
		}
		guard let puzzle = candidates.first, puzzle.moves.count >= 2,
			  engine.loadPosition(fen: puzzle.fen),
			  let openingMove = engine.applyAIMove(puzzle.moves[0]) else {
			puzzleModeActive = false
			gameStarted = false
			let message = "I couldn't set up that puzzle. Please try another."
			lastComputerAnnouncement = message
			currentState = .speakingResponse(message)
			synthesizer.speak(message)
			return
		}
		usedPuzzleIDs.insert(puzzle.id)
		activePuzzle = puzzle
		puzzleModeActive = true
		puzzleSelectionPending = false
		puzzleSolutionIndex = 1
		puzzleSolved = false
		playerColor = engine.board.position.sideToMove == .white ? .white : .black
		moveHistory = ["Puzzle: Mate in \(mateIn)", "Position: \(openingMove.san)"]
		persistCheckpoint()
		beginBoardRead(purpose: .puzzle, mateIn: mateIn)
	}

	private func processPuzzleMove(san: String) {
		guard let puzzle = activePuzzle else { return }
		guard !san.isEmpty, let spokenUCI = engine.uciMove(forSAN: san) else {
			retryListeningAfterInvalidMove()
			return
		}
		let isExpected = puzzle.moves.indices.contains(puzzleSolutionIndex)
			&& spokenUCI == puzzle.moves[puzzleSolutionIndex].lowercased()
		let isAlternateMate = activePuzzleMateCount == 1 && engine.checkmatesWithSAN(san)
		guard isExpected || isAlternateMate, engine.makePlayerMove(san) else {
			let message = "That move misses mate. Try again."
			lastComputerAnnouncement = message
			currentState = .moveRejected(reason: message)
			synthesizer.speak(message)
			return
		}
		moveHistory.append("Player: \(san)")
		if case .checkmate = engine.board.state {
			puzzleSolved = true
			markActivePuzzleCompleted()
			persistCheckpoint()
			let message = "Correct. Checkmate. Say next puzzle for another one, or cancel puzzle to leave puzzle mode."
			lastComputerAnnouncement = message
			currentState = .speakingResponse(message)
			synthesizer.speak(message)
			return
		}
		puzzleSolutionIndex += 1
		playPuzzleReply(in: puzzle)
	}

	private func playPuzzleReply(in puzzle: ChessPuzzle, after prefix: String = "") {
		guard puzzle.moves.indices.contains(puzzleSolutionIndex),
			  let reply = engine.applyAIMove(puzzle.moves[puzzleSolutionIndex]) else {
			puzzleSolved = true
			markActivePuzzleCompleted()
			persistCheckpoint()
			let message = prefix + "Correct. You found the solution. Say next puzzle for another one."
			lastComputerAnnouncement = message
			currentState = .speakingResponse(message)
			synthesizer.speak(message)
			return
		}
		moveHistory.append("Opponent: \(reply.san)")
		puzzleSolutionIndex += 1
		persistCheckpoint()
		let message = prefix + "The opponent plays \(engine.spokenRepresentation(for: reply.san)). Your move."
		lastComputerAnnouncement = message
		currentState = .speakingResponse(message)
		synthesizer.speak(message)
	}

	private func markActivePuzzleCompleted() {
		guard let puzzleID = activePuzzle?.id else { return }
		completedPuzzleIDs.insert(puzzleID)
		sessionStore.recordCompletedPuzzle(puzzleID)
	}

	private var activePuzzleMateCount: Int? {
		guard let themes = activePuzzle?.themes else { return nil }
		if themes.split(separator: " ").contains("mateIn1") { return 1 }
		if themes.split(separator: " ").contains("mateIn2") { return 2 }
		if themes.split(separator: " ").contains("mateIn3") { return 3 }
		return nil
	}

	private func puzzleMateChoice(for mateCount: Int) -> PuzzleMateChoice {
		switch mateCount {
		case 1: .one
		case 2: .two
		default: .three
		}
	}

	private func spokenMateCount(_ mateCount: Int) -> String {
		switch mateCount {
		case 1: "one"
		case 2: "two"
		default: "three"
		}
	}

	private func clearBoardRead() {
		boardReadAfterPuzzleRestore = false
		boardReadRows = []
		boardReadIndex = 0
		boardReadActive = false
		boardCommandReminderPending = false
		boardReadPurpose = nil
		boardReadMateCount = nil
	}

	private func clearPuzzleMode() {
		clearBoardRead()
		puzzleSelectionPending = false
		puzzleModeActive = false
		activePuzzle = nil
		puzzleSolutionIndex = 1
		puzzleSolved = false
		usedPuzzleIDs = []
	}

	private func processVoiceSetupCommand(_ text: String) {
		let words = Set(normalizedCommand(text).split(separator: " ").map(String.init))
		if setupStage == .confirmation {
			if !words.isDisjoint(with: ["yes", "yeah", "yep", "correct", "start"]) {
				startNewGame()
			} else if words.contains("no") || words.contains("nope") {
				setupColorChosen = false
				setupDifficultyChosen = false
				selectedGameChoice = .white
				selectedPuzzleMate = .one
				askForSetupColor()
			} else {
				askForGameConfirmation()
			}
			return
		}

		if words.contains("puzzle") {
			selectedGameChoice = .puzzle
			setupColorChosen = true
			setupDifficultyChosen = false
			setupStage = .puzzleMate
		} else if words.contains("white") {
			selectedGameChoice = .white
			setupColorChosen = true
			setupDifficultyChosen = false
			setupStage = .difficulty
		} else if words.contains("black") {
			selectedGameChoice = .black
			setupColorChosen = true
			setupDifficultyChosen = false
			setupStage = .difficulty
		} else if words.contains("random") {
			selectedGameChoice = .random
			setupColorChosen = true
			setupDifficultyChosen = false
			setupStage = .difficulty
		}

		if selectedGameChoice == .puzzle {
			if setupStage == .puzzleMate {
				if !words.isDisjoint(with: ["one", "won", "1", "single"]) {
					selectedPuzzleMate = .one
					setupDifficultyChosen = true
				} else if !words.isDisjoint(with: ["two", "to", "too", "2"]) {
					selectedPuzzleMate = .two
					setupDifficultyChosen = true
				} else if !words.isDisjoint(with: ["three", "3"]) {
					selectedPuzzleMate = .three
					setupDifficultyChosen = true
				}
			}
		} else if let difficulty = parseDifficulty(from: words) {
			selectedDifficulty = difficulty
			setupDifficultyChosen = true
		}

		if setupColorChosen && setupDifficultyChosen {
			askForGameConfirmation()
			return
		}
		if selectedGameChoice == .puzzle {
			setupStage = .puzzleMate
			setupMessage = "Would you like mate in one, two or three?"
		} else if setupColorChosen {
			setupStage = .difficulty
			setupMessage = "Choose difficulty one to twelve."
		} else if setupDifficultyChosen {
			setupStage = .color
			setupMessage = "Which game would you like: white, black, random, or puzzle?"
		} else {
			setupStage = .color
			setupMessage = "Please say white, black, random, or puzzle. Which game would you like?"
		}
		currentState = .speakingResponse(setupMessage)
		synthesizer.speak(setupMessage)
	}

	private func parseDifficulty(from words: Set<String>) -> ChessDifficulty? {
		if !words.isDisjoint(with: ["one", "won", "1"]) { return .one }
		if !words.isDisjoint(with: ["two", "too", "to", "2"]) { return .two }
		if !words.isDisjoint(with: ["three", "3"]) { return .three }
		if !words.isDisjoint(with: ["four", "for", "4"]) { return .four }
		if !words.isDisjoint(with: ["five", "5"]) { return .five }
		if !words.isDisjoint(with: ["six", "6"]) { return .six }
		if !words.isDisjoint(with: ["seven", "7"]) { return .seven }
		if !words.isDisjoint(with: ["eight", "ate", "8"]) { return .eight }
		if !words.isDisjoint(with: ["nine", "9"]) { return .nine }
		if !words.isDisjoint(with: ["ten", "10"]) { return .ten }
		if !words.isDisjoint(with: ["eleven", "11"]) { return .eleven }
		if !words.isDisjoint(with: ["twelve", "12"]) { return .twelve }
		return nil
	}

	private func askForGameConfirmation() {
		setupStage = .confirmation
		if selectedGameChoice == .puzzle {
			let mateCount = spokenMateCount(selectedPuzzleMate.mateCount)
			setupMessage = "You chose puzzle mode: mate in \(mateCount). Shall I start?"
		} else {
			let color = selectedGameChoice == .random ? "a random colour" : selectedGameChoice.rawValue.lowercased()
			let opponent: String
			if let elo = selectedDifficulty.maiaElo {
				opponent = "level \(selectedDifficulty.rawValue) Maia, \(elo) Elo"
			} else if let elo = selectedDifficulty.estimatedStockfishElo {
				opponent = "level \(selectedDifficulty.rawValue) Stockfish, about \(elo) Elo"
			} else {
				opponent = "level \(selectedDifficulty.rawValue) Stockfish, full strength"
			}
			setupMessage = "You will play as \(color) against \(opponent). Shall I start?"
		}
		currentState = .speakingResponse(setupMessage)
		synthesizer.speak(setupMessage)
	}
	
	private func retryListeningAfterInvalidMove() {
		let heard = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
		let message = heard.isEmpty
			? "I didn't hear a move. Try again."
			: "I heard \(heard). Try again."
		currentState = .moveRejected(reason: message)
		synthesizer.speak(message)
	}

	private func isRepeatCommand(_ text: String) -> Bool {
		let command = text.lowercased()
			.components(separatedBy: CharacterSet.alphanumerics.inverted)
			.filter { !$0.isEmpty }
		return [
			"repeat", "repeat that", "say again", "what was that", "what did you say",
			"come again", "one more time"
		].contains(command.joined(separator: " "))
	}

	private func isHintCommand(_ text: String) -> Bool {
		let command = text.lowercased()
			.components(separatedBy: CharacterSet.alphanumerics.inverted)
			.filter { !$0.isEmpty }
		return [
			"hint", "give me a hint", "suggest a move", "suggest move",
			"what should i play", "what move should i play"
		].contains(command.joined(separator: " "))
	}

	private func requestHint() {
		currentState = .thinking
		let fen = engine.board.position.fen
		Task { @MainActor [weak self] in
			guard let self else { return }
			do {
				let uciMove = try await stockfish.bestMove(fen: fen, difficulty: .twelve)
				guard case .thinking = currentState,
					  let san = engine.sanForUCIMove(uciMove) else { return }
				let message = "One suggestion is \(engine.spokenRepresentation(for: san))."
				lastComputerAnnouncement = message
				currentState = .speakingResponse(message)
				synthesizer.speak(message)
			} catch {
				guard case .thinking = currentState else { return }
				let message = "I couldn't find a suggestion right now. Try again."
				lastComputerAnnouncement = message
				currentState = .speakingResponse(message)
				synthesizer.speak(message)
			}
		}
	}

	func repeatLastMoveAnnouncement() {
		guard let announcement = lastMoveAnnouncement else {
			let message = "I haven't announced a move yet."
			currentState = .speakingResponse(message)
			synthesizer.speak(message)
			return
		}
		recognitionTimeout?.cancel()
		pauseTask?.cancel()
		speechManager.stopListening()
		currentState = .speakingResponse(announcement)
		synthesizer.speak(announcement)
	}

	private func processAITurn(playerSan: String?) {
		currentState = .thinking
		let difficulty = selectedDifficulty
		if let maiaElo = difficulty.maiaElo {
			let positionHistoryFENs = engine.positionHistoryFENs
			let legalUCIMoves = engine.legalUCIMoves
			Task { @MainActor [weak self] in
				guard let self else { return }
				do {
					let uciMove = try await maia.bestMove(
						positionHistoryFENs: positionHistoryFENs,
						legalUCIMoves: legalUCIMoves,
						elo: maiaElo
					)
					guard case .thinking = currentState,
						  let aiMove = engine.applyAIMove(uciMove) else { return }
					announceAIMove(aiMove, respondingTo: playerSan)
				} catch {
					guard case .thinking = currentState else { return }
					let message = "Maia couldn't calculate a move. \(error.localizedDescription) Please start a new game."
					currentState = .gameOver(message)
					lastComputerAnnouncement = message
					synthesizer.speak(message)
				}
			}
			return
		}
		let fen = engine.board.position.fen
		Task { @MainActor [weak self] in
			guard let self else { return }
			do {
				let uciMove = try await stockfish.bestMove(fen: fen, difficulty: difficulty)
				guard case .thinking = currentState,
					  let aiMove = engine.applyAIMove(uciMove) else { return }
				announceAIMove(aiMove, respondingTo: playerSan)
			} catch {
				guard case .thinking = currentState else { return }
				let message = "Stockfish couldn't calculate a move. \(error.localizedDescription) Please start a new game."
				currentState = .gameOver(message)
				lastComputerAnnouncement = message
				synthesizer.speak(message)
			}
		}
	}

	private func announceAIMove(_ aiMove: (san: String, start: Square, end: Square), respondingTo playerSan: String?) {
		moveHistory.append("AI: \(aiMove.san)")
		let aiSpoken = engine.spokenRepresentation(for: aiMove.san)
		let moveAnnouncement = "I play \(aiSpoken)."
		lastMoveAnnouncement = moveAnnouncement
		if finishGameIfNeeded(lastMove: aiMove.san) { return }
		pendingDangerAnnouncement = engine.immediateDangerAnnouncement(for: playerColor == .white ? .white : .black)

		let speechText = playerSan.map {
			"You played \(engine.spokenRepresentation(for: $0)). I play \(aiSpoken)."
		} ?? "I play \(aiSpoken)."
		lastComputerAnnouncement = speechText
		currentState = .speakingResponse(speechText)
		persistCheckpoint()
		synthesizer.speak(speechText)
	}
	
	private func finishGameIfNeeded(lastMove: String? = nil) -> Bool {
		let result: String
		switch engine.board.state {
		case .checkmate(let matedColor):
			let winningColor = matedColor.opposite
			let playerWon = playerColor.pieceColor.map { winningColor == $0 } ?? false
			result = playerWon ? "Checkmate. You win." : "Checkmate. I win."
		case .draw: result = "Draw."
		default: return false
		}
		currentState = .gameOver(result)
		let announcement = lastMove.map { "I play \(engine.spokenRepresentation(for: $0)). " } ?? ""
		let speechText = announcement + result
		lastComputerAnnouncement = speechText
		persistCheckpoint()
		synthesizer.speak(speechText)
		return true
	}

	private func handleSpeechFinished() {
		switch currentState {
		case .speakingResponse where pendingSessionConfirmation != nil:
			startPlayerTurn()
		case .speakingResponse:
			if let announcement = pendingDangerAnnouncement {
				pendingDangerAnnouncement = nil
				currentState = .speakingResponse(announcement)
				synthesizer.speak(announcement)
				return
			}
			if boardReadAfterPuzzleRestore {
				boardReadAfterPuzzleRestore = false
				beginBoardRead(purpose: .callout, mateIn: nil)
				return
			}
			if boardReadActive,
			   boardReadRows.indices.contains(boardReadIndex),
			   boardReadRows[boardReadIndex].contains(" is empty.") {
				if boardReadIndex + 1 < boardReadRows.count {
					boardReadIndex += 1
					speakBoardReadRow()
					return
				}
				finishBoardRead()
				return
			}
			currentState = .waitingForPlayer
			if startGameAfterColorAnnouncement {
				startGameAfterColorAnnouncement = false
				if playerColor == .white {
					startPlayerTurn()
				} else {
					processAITurn(playerSan: nil)
				}
			} else if resumeAITurnAfterAnnouncement {
				resumeAITurnAfterAnnouncement = false
				processAITurn(playerSan: nil)
			} else {
				startPlayerTurn()
			}
		case .moveRejected, .gameOver:
			currentState = .waitingForPlayer
			startPlayerTurn()
		default:
			break
		}
	}
}
