import Foundation

enum SavedGameMode: String, Codable {
	case standard
	case puzzle
}

struct SavedGameSnapshot: Codable {
	let mode: SavedGameMode
	let positionFEN: String
	let undoPositionFENs: [String]
	let selectedGameChoice: GameChoice
	let playerColor: PlayerColorChoice
	let difficulty: ChessDifficulty
	let moveHistory: [String]
	let lastComputerAnnouncement: String?
	let lastMoveAnnouncement: String?
	let puzzleID: String?
	let puzzleSolutionIndex: Int
	let puzzleSolved: Bool
	let usedPuzzleIDs: [String]
	let completedPuzzleIDs: [String]
	let gameOverMessage: String?

	var isFinished: Bool { puzzleSolved || gameOverMessage != nil }
}

final class GameSessionStore {
	static let shared = GameSessionStore()

	private let defaults = UserDefaults.standard
	private let checkpointKey = "voicechess.game.checkpoint.v1"
	private let savedGameKey = "voicechess.game.saved.v1"
	private let completedPuzzlesKey = "voicechess.puzzles.completed.v1"

	private init() {}

	var completedPuzzleIDs: Set<String> {
		Set(defaults.stringArray(forKey: completedPuzzlesKey) ?? [])
	}

	func recordCompletedPuzzle(_ id: String) {
		var completed = completedPuzzleIDs
		completed.insert(id)
		saveCompletedPuzzleIDs(completed)
	}

	func saveCompletedPuzzleIDs(_ ids: Set<String>) {
		defaults.set(ids.sorted(), forKey: completedPuzzlesKey)
	}

	func saveCheckpoint(_ snapshot: SavedGameSnapshot) {
		defaults.set(try? JSONEncoder().encode(snapshot), forKey: checkpointKey)
	}

	func loadCheckpoint() -> SavedGameSnapshot? {
		guard let data = defaults.data(forKey: checkpointKey) else { return nil }
		return try? JSONDecoder().decode(SavedGameSnapshot.self, from: data)
	}

	func clearCheckpoint() {
		defaults.removeObject(forKey: checkpointKey)
	}

	func saveManualGame(_ snapshot: SavedGameSnapshot) {
		defaults.set(try? JSONEncoder().encode(snapshot), forKey: savedGameKey)
	}

	func clearManualGame() {
		defaults.removeObject(forKey: savedGameKey)
	}

	func loadManualGame() -> SavedGameSnapshot? {
		guard let data = defaults.data(forKey: savedGameKey) else { return nil }
		return try? JSONDecoder().decode(SavedGameSnapshot.self, from: data)
	}
}
