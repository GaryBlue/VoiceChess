import Foundation
@preconcurrency import CoreML

@MainActor
final class MaiaCoreMLEngineManager {
	private enum MaiaError: LocalizedError {
		case modelMissing
		case invalidPosition
		case invalidModelOutput(String)
		case noLegalMove

		var errorDescription: String? {
			switch self {
			case .modelMissing: "Maia's model is missing from the app."
			case .invalidPosition: "Maia couldn't read the current board position."
			case .invalidModelOutput(let details): "Maia returned an unexpected result: \(details)"
			case .noLegalMove: "Maia couldn't choose a legal move."
			}
		}
	}

	private var modelTask: Task<MLModel, Error>?

	func bestMove(positionHistoryFENs: [String], legalUCIMoves: [String], elo: Int = 1000) async throws -> String {
		let model = try await loadModel()
		return try await Task.detached(priority: .userInitiated) {
			try Self.predict(
				model: model,
				positionHistoryFENs: positionHistoryFENs,
				legalUCIMoves: legalUCIMoves,
				elo: elo
			)
		}.value
	}

	private func loadModel() async throws -> MLModel {
		if modelTask == nil {
			guard let modelURL = Bundle.main.url(forResource: "Maia3-5M", withExtension: "mlmodelc") else {
				throw MaiaError.modelMissing
			}
			modelTask = Task.detached(priority: .utility) {
				let configuration = MLModelConfiguration()
				configuration.computeUnits = .all
				return try MLModel(contentsOf: modelURL, configuration: configuration)
			}
		}
		guard let modelTask else { throw MaiaError.modelMissing }
		return try await modelTask.value
	}

	private nonisolated static func predict(
		model: MLModel,
		positionHistoryFENs: [String],
		legalUCIMoves: [String],
		elo: Int
	) throws -> String {
		guard let currentFEN = positionHistoryFENs.last,
			  let currentFields = fenFields(currentFEN) else { throw MaiaError.invalidPosition }
		let blackToMove = currentFields.sideToMoveIsBlack
		let tokens = try makeInputTokens(from: positionHistoryFENs)
		let selfElo = try makeEloInput(elo)
		let opponentElo = try makeEloInput(elo)
		let input = try MLDictionaryFeatureProvider(dictionary: [
			"tokens": MLFeatureValue(multiArray: tokens),
			"self_elo": MLFeatureValue(multiArray: selfElo),
			"opponent_elo": MLFeatureValue(multiArray: opponentElo),
		])
		let output = try model.prediction(from: input)
		guard let scores = output.featureValue(for: "move_logits")?.multiArrayValue else {
			let names = output.featureNames.sorted().joined(separator: ", ")
			throw MaiaError.invalidModelOutput("missing move_logits output (received: \(names)).")
		}
		guard scores.count == 4352 else {
			throw MaiaError.invalidModelOutput("expected 4,352 move scores, received \(scores.count).")
		}
		let scoreValues: [Double]
		switch scores.dataType {
		case .float16:
			let values = scores.dataPointer.bindMemory(to: Float16.self, capacity: scores.count)
			scoreValues = (0..<scores.count).map { Double(values[$0]) }
		case .float32:
			let values = scores.dataPointer.bindMemory(to: Float32.self, capacity: scores.count)
			scoreValues = (0..<scores.count).map { Double(values[$0]) }
		case .double:
			let values = scores.dataPointer.bindMemory(to: Double.self, capacity: scores.count)
			scoreValues = (0..<scores.count).map { values[$0] }
		default:
			throw MaiaError.invalidModelOutput("unsupported move score type \(scores.dataType.rawValue).")
		}
		let candidates = legalUCIMoves.compactMap { uci -> (uci: String, score: Double)? in
			guard let index = moveIndex(for: uci, blackToMove: blackToMove) else { return nil }
			return (uci, scoreValues[index])
		}
		guard let maxScore = candidates.map(\.score).max(), !candidates.isEmpty else {
			throw MaiaError.noLegalMove
		}

		// Maia predicts a distribution of human moves; sample the legal move
		// probabilities rather than always selecting the highest-scoring move.
		let weights = candidates.map { exp($0.score - maxScore) }
		let totalWeight = weights.reduce(0, +)
		guard totalWeight.isFinite, totalWeight > 0 else { throw MaiaError.noLegalMove }
		var draw = Double.random(in: 0..<totalWeight)
		for (candidate, weight) in zip(candidates, weights) {
			draw -= weight
			if draw <= 0 { return candidate.uci }
		}
		guard let last = candidates.last else { throw MaiaError.noLegalMove }
		return last.uci
	}

	private nonisolated static func makeInputTokens(from positionHistoryFENs: [String]) throws -> MLMultiArray {
		let retainedPositions = Array(positionHistoryFENs.suffix(8))
		guard let earliestPosition = retainedPositions.first else { throw MaiaError.invalidPosition }
		let paddedPositions = Array(repeating: earliestPosition, count: 8 - retainedPositions.count) + retainedPositions
		let tokens = try MLMultiArray(shape: [1, 64, 97], dataType: .float32)
		let values = tokens.dataPointer.bindMemory(to: Float32.self, capacity: tokens.count)
		for index in 0..<tokens.count { values[index] = 0 }

		for (historyIndex, fen) in paddedPositions.enumerated() {
			guard let fields = fenFields(fen), fields.rows.count == 8 else { throw MaiaError.invalidPosition }
			for (rowIndex, row) in fields.rows.enumerated() {
				var file = 0
				for character in row {
					if let emptySquares = character.wholeNumberValue {
						file += emptySquares
						continue
					}
					guard file < 8,
						  let pieceIndex = pieceChannel(for: character) else { throw MaiaError.invalidPosition }
					let unmirroredRank = 7 - rowIndex
					let modelRank = fields.sideToMoveIsBlack ? 7 - unmirroredRank : unmirroredRank
					let square = modelRank * 8 + file
					let pieceIsSideToMoveColor = character.isUppercase != fields.sideToMoveIsBlack
					let colorOffset = pieceIsSideToMoveColor ? 0 : 6
					let feature = historyIndex * 12 + colorOffset + pieceIndex
					values[square * 97 + feature] = 1
					file += 1
				}
				guard file == 8 else { throw MaiaError.invalidPosition }
			}
		}
		return tokens
	}

	private nonisolated static func makeEloInput(_ elo: Int) throws -> MLMultiArray {
		let values = try MLMultiArray(shape: [1], dataType: .float32)
		values.dataPointer.bindMemory(to: Float32.self, capacity: 1)[0] = Float32(elo)
		return values
	}

	private struct FENFields {
		let rows: [String]
		let sideToMoveIsBlack: Bool
	}

	private nonisolated static func fenFields(_ fen: String) -> FENFields? {
		let parts = fen.split(whereSeparator: \.isWhitespace)
		guard parts.count >= 2 else { return nil }
		let rows = parts[0].split(separator: "/").map(String.init)
		guard rows.count == 8, parts[1] == "w" || parts[1] == "b" else { return nil }
		return FENFields(rows: rows, sideToMoveIsBlack: parts[1] == "b")
	}

	private nonisolated static func pieceChannel(for piece: Character) -> Int? {
		switch piece.lowercased() {
		case "p": 0
		case "n": 1
		case "b": 2
		case "r": 3
		case "q": 4
		case "k": 5
		default: nil
		}
	}

	private nonisolated static func moveIndex(for uci: String, blackToMove: Bool) -> Int? {
		let characters = Array(uci.lowercased())
		guard characters.count == 4 || characters.count == 5,
			  let fromFile = fileIndex(characters[0]),
			  let toFile = fileIndex(characters[2]),
			  let fromRank = Int(String(characters[1])),
			  let toRank = Int(String(characters[3])),
			  (1...8).contains(fromRank), (1...8).contains(toRank) else { return nil }
		let modelFromRank = blackToMove ? 9 - fromRank : fromRank
		let modelToRank = blackToMove ? 9 - toRank : toRank
		if characters.count == 5 {
			guard modelFromRank == 7, modelToRank == 8 else { return nil }
			let promotionPiece: Int
			switch characters[4] {
			case "q": promotionPiece = 0
			case "r": promotionPiece = 1
			case "b": promotionPiece = 2
			case "n": promotionPiece = 3
			default: return nil
			}
			return 4096 + fromFile * 32 + toFile * 4 + promotionPiece
		}
		let fromSquare = (modelFromRank - 1) * 8 + fromFile
		let toSquare = (modelToRank - 1) * 8 + toFile
		return fromSquare * 64 + toSquare
	}

	private nonisolated static func fileIndex(_ file: Character) -> Int? {
		guard let ascii = file.asciiValue, (97...104).contains(ascii) else { return nil }
		return Int(ascii - 97)
	}
}
