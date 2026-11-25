import Foundation
import ChessKit
import SFEngine

enum ChessDifficulty: String, CaseIterable, Identifiable, Codable {
	case one = "1"
	case two = "2"
	case three = "3"
	case four = "4"
	case five = "5"
	case six = "6"
	case seven = "7"
	case eight = "8"
	case nine = "9"
	case ten = "10"
	case eleven = "11"
	case twelve = "12"
	var id: String { rawValue }

	// Older saves used bare level numbers, starting with Maia 800 at level 1.
	init(from decoder: Decoder) throws {
		let container = try decoder.singleValueContainer()
		let stored = try container.decode(String.self)
		if stored.hasPrefix("level-"), let level = Self(rawValue: String(stored.dropFirst(6))) {
			self = level
		} else if let oldLevel = Int(stored), (1...11).contains(oldLevel),
				  let level = Self(rawValue: String(oldLevel + 1)) {
			self = level
		} else {
			throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown difficulty: \(stored)")
		}
	}

	func encode(to encoder: Encoder) throws {
		var container = encoder.singleValueContainer()
		try container.encode("level-\(rawValue)")
	}

	var skillLevel: Int {
		switch self {
		case .one, .two, .three, .four, .five, .six, .seven, .eight: 0
		case .nine: 5
		case .ten: 9
		case .eleven: 14
		case .twelve: 20
		}
	}

	var maiaElo: Int? {
		switch self {
		case .one: 600
		case .two: 800
		case .three: 1000
		case .four: 1200
		case .five: 1400
		case .six: 1600
		case .seven: 1800
		case .eight: 2000
		case .nine, .ten, .eleven, .twelve: nil
		}
	}

	/// Rounded Stockfish skill-level ratings; the app's shorter think times make these approximate.
	var estimatedStockfishElo: Int? {
		switch self {
		case .nine: 2200
		case .ten: 2700
		case .eleven: 3000
		case .one, .two, .three, .four, .five, .six, .seven, .eight, .twelve: nil
		}
	}

	var moveTimeMilliseconds: Int {
		switch self {
		case .one, .two, .three, .four, .five, .six, .seven, .eight: 0
		case .nine: 300
		case .ten: 600
		case .eleven: 1200
		case .twelve: 1800
		}
	}
}

final class ChessEngineManager {
	private struct KingSafetyViolation {
		let attacker: Piece?
		let kingWasAlreadyInCheck: Bool
	}

	private(set) var board: Board
	private var previousBoards: [Board] = []
	
	init() {
		self.board = Board()
	}
	
	func resetGame() {
		self.board = Board()
		previousBoards = []
	}

	@discardableResult
	func loadPosition(fen: String, undoPositionFENs: [String] = []) -> Bool {
		guard let position = Position(fen: fen) else { return false }
		let history = undoPositionFENs.compactMap { fen -> Board? in
			guard let position = Position(fen: fen) else { return nil }
			return Board(position: position)
		}
		guard history.count == undoPositionFENs.count else { return false }
		board = Board(position: position)
		previousBoards = history
		return true
	}

	var undoPositionFENs: [String] { previousBoards.map { $0.position.fen } }

	var positionHistoryFENs: [String] {
		previousBoards.map { $0.position.fen } + [board.position.fen]
	}

	var legalUCIMoves: [String] {
		var moves: [String] = []
		for start in Square.allCases {
			guard let piece = board.position.piece(at: start),
				  piece.color == board.position.sideToMove else { continue }
			for end in board.legalMoves(forPieceAt: start) {
				let prefix = start.notation.lowercased() + end.notation.lowercased()
				if piece.kind == .pawn && (end.rank.value == 1 || end.rank.value == 8) {
					moves.append(contentsOf: ["q", "r", "b", "n"].map { prefix + $0 })
				} else {
					moves.append(prefix)
				}
			}
		}
		return moves
	}

	var canUndoLastTurn: Bool { previousBoards.count >= 2 }

	/// Short phrases that match legal spoken moves in the current position.
	var speechContextualStrings: [String] {
		let fileNames = ["a", "b", "c", "d", "e", "f", "g", "h"]
		let rankNames = ["one", "two", "three", "four", "five", "six", "seven", "eight"]
		var destinations = Set<String>()
		var coordinateDestinations = Set<String>()
		var legalCapturePhrases = Set<String>()
		var legalQuietMovePhrases = Set<String>()

		for start in Square.allCases {
			guard let piece = board.position.piece(at: start),
				  piece.color == board.position.sideToMove else { continue }
			for end in board.legalMoves(forPieceAt: start) {
				let notation = end.notation.lowercased()
				let chars = Array(notation)
				guard chars.count == 2,
					  let fileIndex = fileNames.firstIndex(of: String(chars[0])),
					  let rank = Int(String(chars[1])), (1...8).contains(rank) else { continue }
				let spokenSquare = "\(fileNames[fileIndex]) \(rankNames[rank - 1])"
				destinations.insert(spokenSquare)
				coordinateDestinations.insert(notation)
				let isCapture = piece.kind == .pawn
					? start.file != end.file
					: board.position.piece(at: end)?.color == piece.color.opposite
			let action = isCapture ? "takes" : "to"
			let phrase = "\(piece.kind) \(action) \(spokenSquare)".lowercased()
			if isCapture {
				legalCapturePhrases.insert(phrase)
			} else {
				legalQuietMovePhrases.insert(phrase)
			}
			}
		}

		let commonPhrases = [
			"pawn", "knight", "bishop", "rook", "queen", "king", "pawn to", "knight to", "bishop to",
			"rook to", "queen to", "king to", "pawn takes", "knight takes", "bishop takes", "rook takes",
			"horse to", "horse takes", "castle to", "castle takes", "tower to", "tower takes",
			"queen takes", "king takes", "takes", "capture", "castles kingside",
			"castles queenside", "en passant", "promote to queen", "promote to rook", "promote to bishop",
			"promote to knight", "board", "repeat", "undo", "hint", "suggest a move", "new game", "random", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
			"level one", "level two", "level three", "level four", "level five", "level six", "level seven", "level eight", "level nine", "level ten", "level eleven", "level twelve", "yes", "no",
			"puzzle", "puzzle mode", "mate in one", "mate in two", "mate in three", "next puzzle", "continue", "repeat", "cancel",
			"save game", "load game", "resume saved game"
		]
		let allPhrases = commonPhrases + legalCapturePhrases.sorted() + destinations.sorted()
			+ coordinateDestinations.sorted() + legalQuietMovePhrases.sorted()
		var seen = Set<String>()
		return Array(allPhrases.filter { seen.insert($0).inserted }.prefix(100))
	}

	@discardableResult
	func undoLastMove() -> Bool {
		guard let previousBoard = previousBoards.popLast() else { return false }
		board = previousBoard
		return true
	}

	/// Makes a uniformly random legal move.
	func makeRandomLegalMove() -> (san: String, start: Square, end: Square)? {
		let candidates = Square.allCases.flatMap { start -> [(Square, Square)] in
			guard let piece = board.position.piece(at: start),
				  piece.color == board.position.sideToMove else { return [] }
			return board.legalMoves(forPieceAt: start).map { (start, $0) }
		}
		guard let (start, end) = candidates.randomElement() else { return nil }
		let previousBoard = board
		guard var move = board.move(pieceAt: start, to: end) else { return nil }
		previousBoards.append(previousBoard)
		if case .promotion = board.state {
			move = board.completePromotion(of: move, to: .queen)
		}
		return (move.san, start, end)
	}

	func spokenBoardDescription() -> String {
		var lines = ["The board, from rank eight down to rank one."]
		lines.append(contentsOf: spokenBoardRows())
		lines.append("\(board.position.sideToMove) to move.")
		switch board.state {
		case .check(let color): lines.append("\(color) is in check.")
		case .checkmate(let color): lines.append("\(color) is checkmated.")
		case .draw: lines.append("The game is drawn.")
		default: break
		}
		return lines.joined(separator: " ")
	}

	func spokenBoardRows() -> [String] {
		var lines: [String] = []
		for rank in (1...8).reversed() {
			let squares = Square.allCases
				.filter { $0.rank.value == rank }
				.sorted { $0.file.number < $1.file.number }
			let pieces = squares.compactMap { square -> String? in
				guard let piece = board.position.piece(at: square) else { return nil }
			let file = String(describing: square.file.rawValue).uppercased()
			return "\(piece.color) \(piece.kind) on \(file)"
			}
			lines.append(pieces.isEmpty ? "Rank \(rank) is empty." : "Rank \(rank): \(pieces.joined(separator: ". ")).")
		}
		return lines
	}

	/// Finds a high-value piece that can be captured immediately without a legal recapture.
	func immediateDangerAnnouncement(for playerColor: Piece.Color) -> String? {
		guard board.position.sideToMove == playerColor,
			  case .active = board.state else { return nil }

		var threats: [(target: Square, victim: Piece, attacker: Piece, canRecapture: Bool, materialLoss: Int)] = []
		for attackerSquare in Square.allCases {
			guard let attacker = board.position.piece(at: attackerSquare),
				  attacker.color == playerColor.opposite else { continue }
			for target in board.legalMoves(forPieceAt: attackerSquare) {
				guard let victim = board.position.piece(at: target),
					  victim.color == playerColor,
					  victim.kind != .king,
					  pieceValue(victim.kind) >= 3 else { continue }

				var afterCapture = board
				guard afterCapture.move(pieceAt: attackerSquare, to: target) != nil else { continue }
				let canRecapture = Square.allCases.contains { defenderSquare in
					guard let defender = afterCapture.position.piece(at: defenderSquare),
						  defender.color == playerColor else { return false }
					return afterCapture.legalMoves(forPieceAt: defenderSquare).contains(target)
				}
				let materialLoss = pieceValue(victim.kind) - (canRecapture ? pieceValue(attacker.kind) : 0)
				if materialLoss > 0 {
					threats.append((target, victim, attacker, canRecapture, materialLoss))
				}
			}
		}

		guard let threat = threats.max(by: { $0.materialLoss < $1.materialLoss }) else {
			return nil
		}
		let warning = "Your \(threat.victim.kind) on \(threat.target.notation.uppercased()) is in danger. My \(threat.attacker.kind) on \(threat.attacker.square.notation.uppercased()) can take it."
		if threat.canRecapture {
			return "\(warning) You can take my \(threat.attacker.kind) back, but you would lose your \(threat.victim.kind) for my \(threat.attacker.kind)."
		}
		return "\(warning) You can't take my \(threat.attacker.kind) back."
	}

	private func pieceValue(_ kind: Piece.Kind) -> Int {
		switch kind {
		case .pawn: 1
		case .knight, .bishop: 3
		case .rook: 5
		case .queen: 9
		case .king: 100
		}
	}
	
	func isLegalPlayerMove(_ san: String) -> Bool {
		if san.hasPrefix("x") {
			guard let expanded = inferredPawnCaptureSAN(san) else { return false }
			return isLegalPlayerMove(expanded)
		}
		guard let move = Move(san: san, position: board.position),
			  move.piece.color == board.position.sideToMove else { return false }
		return board.legalMoves(forPieceAt: move.start).contains(move.end)
	}

	/// Validates and executes a parsed SAN string (e.g. "e4", "Nf3", "Bxf7+")
	func makePlayerMove(_ san: String) -> Bool {
		// Spoken pawn captures often omit the pawn's starting file ("takes d4").
		// Infer it only when exactly one legal pawn can capture that destination.
		if san.hasPrefix("x") {
			guard let expanded = inferredPawnCaptureSAN(san) else { return false }
			return makePlayerMove(expanded)
		}

		// 1. Parse SAN into Move for the current board position
		guard let move = Move(san: san, position: board.position) else {
			return false
		}
		
		// 2. Verify destination square is legal for piece at start square
		let legalTargets = board.legalMoves(forPieceAt: move.start)
		guard legalTargets.contains(move.end) else {
			return false
		}
		
		// 3. Apply move to board
		guard move.piece.color == board.position.sideToMove else { return false }
		let previousBoard = board
		guard let applied = board.move(pieceAt: move.start, to: move.end) else { return false }
		previousBoards.append(previousBoard)
		if case .promotion = board.state {
			board.completePromotion(of: applied, to: move.promotedPiece?.kind ?? .queen)
		}
		return true
	}

	/// Returns a spoken explanation only when the move's intent identifies a clear cause.
	func illegalMoveExplanation(for san: String) -> String? {
		let text = san.trimmingCharacters(in: .whitespacesAndNewlines)
		let coordinateText = text.lowercased()
		if coordinateText.count == 4 {
			let chars = Array(coordinateText)
			let sourceText = String(chars.prefix(2))
			let destinationText = String(chars.suffix(2))
			let source = Square(sourceText)
			let destination = Square(destinationText)
			if source.notation == sourceText, destination.notation == destinationText {
				guard let piece = board.position.piece(at: source) else {
					return "There's no piece on \(sourceText.uppercased())."
				}
				guard piece.color == board.position.sideToMove else {
					return "It's \(board.position.sideToMove)'s turn, but the piece on \(sourceText.uppercased()) is \(piece.color)."
				}
				if let target = board.position.piece(at: destination), target.color == piece.color {
					return "\(destinationText.uppercased()) is occupied by your own piece."
				}
				if pseudoLegalMove(from: source, to: destination, isCapture: nil),
				   let violation = kingSafetyViolation(from: source, to: destination) {
					return kingSafetyExplanation(
						piece: piece,
						from: source,
					to: destination,
						violation: violation
					)
				}
				return "Your \(piece.kind) on \(sourceText.uppercased()) can't legally move to \(destinationText.uppercased())."
			}
		}

		let sanText = text.replacingOccurrences(of: "+", with: "")
			.replacingOccurrences(of: "#", with: "")
		guard sanText.count >= 2 else { return nil }
		let destinationText = String(sanText.suffix(2)).lowercased()
		let destination = Square(destinationText)
		guard destination.notation == destinationText else { return nil }

		let prefix = String(sanText.dropLast(2))
		let isCapture = prefix.contains("x")
		let prefixWithoutCapture = prefix.replacingOccurrences(of: "x", with: "")
		let first = prefixWithoutCapture.first
		let pieceKind: Piece.Kind
		let disambiguation: String
		if let first, let kind = Piece.Kind.allCases.first(where: { $0.notation == String(first) && !$0.notation.isEmpty }) {
			pieceKind = kind
			disambiguation = String(prefixWithoutCapture.dropFirst())
		} else {
			pieceKind = .pawn
			disambiguation = prefixWithoutCapture
		}

		let candidates = Square.allCases.filter { source in
			guard let piece = board.position.piece(at: source),
				  piece.kind == pieceKind,
				  piece.color == board.position.sideToMove else { return false }
			if disambiguation.contains(where: { "abcdefgh".contains($0) }),
			   !source.notation.hasPrefix(String(disambiguation.first(where: { "abcdefgh".contains($0) })!)) {
				return false
			}
			if let rank = disambiguation.first(where: { "12345678".contains($0) }),
			   !source.notation.hasSuffix(String(rank)) {
				return false
			}
			return board.legalMoves(forPieceAt: source).contains(destination)
		}

		let selfCheckCandidates = Square.allCases.compactMap { source -> (Square, Piece, KingSafetyViolation)? in
			guard let piece = board.position.piece(at: source),
				  piece.kind == pieceKind,
				  piece.color == board.position.sideToMove else { return nil }
			if let file = disambiguation.first(where: { "abcdefgh".contains($0) }),
			   !source.notation.hasPrefix(String(file)) { return nil }
			if let rank = disambiguation.first(where: { "12345678".contains($0) }),
			   !source.notation.hasSuffix(String(rank)) { return nil }
			guard pseudoLegalMove(from: source, to: destination, isCapture: isCapture),
				  let violation = kingSafetyViolation(from: source, to: destination) else { return nil }
			return (source, piece, violation)
		}
		if let (source, piece, violation) = selfCheckCandidates.first {
			return kingSafetyExplanation(piece: piece, from: source, to: destination, violation: violation)
		}

		if candidates.count > 1 {
			return "More than one \(pieceKind) can move to \(destinationText.uppercased()). Say its starting square."
		}
		guard candidates.isEmpty else { return nil }
		if isCapture, pieceKind == .pawn {
			return "No pawn can legally capture on \(destinationText.uppercased())."
		}
		if pieceKind == .pawn, !isCapture,
		   let target = board.position.piece(at: destination) {
			let owner = target.color == board.position.sideToMove ? "your own piece" : "an opponent's piece"
			return "\(destinationText.uppercased()) is occupied by \(owner), so a pawn can't move there."
		}
		if !disambiguation.isEmpty {
			return "No \(pieceKind) from \(disambiguation) can legally move to \(destinationText.uppercased())."
		}
		return "No \(pieceKind) can legally move to \(destinationText.uppercased())."
	}

	private func pseudoLegalMove(from start: Square, to end: Square, isCapture expectedCapture: Bool?) -> Bool {
		guard start != end,
			  let piece = board.position.piece(at: start),
			  piece.color == board.position.sideToMove else { return false }
		let target = board.position.piece(at: end)
		guard target?.color != piece.color, target?.kind != .king else { return false }

		let fileDelta = end.file.number - start.file.number
		let rankDelta = end.rank.value - start.rank.value
		let isEnPassant = piece.kind == .pawn && target == nil
			&& board.position.fen.split(separator: " ").dropFirst(3).first.map(String.init) == end.notation
		let isCapture = target != nil || isEnPassant
		if let expectedCapture, expectedCapture != isCapture { return false }

		switch piece.kind {
		case .pawn:
			let direction = piece.color == .white ? 1 : -1
			if isCapture {
				return abs(fileDelta) == 1 && rankDelta == direction
			}
			guard fileDelta == 0, target == nil, !isEnPassant else { return false }
			if rankDelta == direction { return true }
			let startingRank = piece.color == .white ? 2 : 7
			guard start.rank.value == startingRank, rankDelta == 2 * direction else { return false }
			let middle = Square("\(start.file.rawValue)\(start.rank.value + direction)")
			return board.position.piece(at: middle) == nil
		case .knight:
			return (abs(fileDelta) == 1 && abs(rankDelta) == 2)
				|| (abs(fileDelta) == 2 && abs(rankDelta) == 1)
		case .king:
			return max(abs(fileDelta), abs(rankDelta)) == 1
		case .rook, .bishop, .queen:
			let isStraight = fileDelta == 0 || rankDelta == 0
			let isDiagonal = abs(fileDelta) == abs(rankDelta)
			guard piece.kind == .queen ? (isStraight || isDiagonal)
				: piece.kind == .rook ? isStraight : isDiagonal else { return false }
			let fileStep = fileDelta == 0 ? 0 : fileDelta / abs(fileDelta)
			let rankStep = rankDelta == 0 ? 0 : rankDelta / abs(rankDelta)
			var file = start.file.number + fileStep
			var rank = start.rank.value + rankStep
			while file != end.file.number || rank != end.rank.value {
				let square = Square("\(Square.File(file).rawValue)\(rank)")
				guard board.position.piece(at: square) == nil else { return false }
				file += fileStep
				rank += rankStep
			}
			return true
		}
	}

	private func kingSafetyViolation(from start: Square, to end: Square) -> KingSafetyViolation? {
		guard let movingPiece = board.position.piece(at: start) else { return nil }
		let fields = board.position.fen.split(separator: " ").map(String.init)
		guard fields.count >= 6 else { return nil }

		var squares = Array(repeating: Array(repeating: Character(" "), count: 8), count: 8)
		for piece in board.position.pieces {
			let symbol = piece.kind == .pawn ? "P" : piece.kind.notation
			let fenSymbol = piece.color == .white ? symbol : symbol.lowercased()
			squares[8 - piece.square.rank.value][piece.square.file.number - 1] = Character(fenSymbol)
		}

		squares[8 - start.rank.value][start.file.number - 1] = " "
		if movingPiece.kind == .pawn,
		   board.position.piece(at: end) == nil,
		   abs(end.file.number - start.file.number) == 1 {
			let direction = movingPiece.color == .white ? 1 : -1
			let capturedPawnRank = end.rank.value - direction
			squares[8 - capturedPawnRank][end.file.number - 1] = " "
		}
		let movingSymbol = movingPiece.kind == .pawn ? "P" : movingPiece.kind.notation
		squares[8 - end.rank.value][end.file.number - 1] = Character(
			movingPiece.color == .white ? movingSymbol : movingSymbol.lowercased()
		)

		let placement = squares.map { rank in
			var encoded = ""
			var emptyCount = 0
			for square in rank {
				if square == " " {
					emptyCount += 1
				} else {
					if emptyCount > 0 { encoded += String(emptyCount); emptyCount = 0 }
					encoded.append(square)
				}
			}
			if emptyCount > 0 { encoded += String(emptyCount) }
			return encoded
		}.joined(separator: "/")
		var resultingFields = fields
		resultingFields[0] = placement
		resultingFields[1] = movingPiece.color == .white ? "b" : "w"
		guard let resultingPosition = Position(fen: resultingFields.joined(separator: " ")) else { return nil }
		let resultingBoard = Board(position: resultingPosition)
		let wasAlreadyInCheck: Bool
		if case .check(let color) = board.state { wasAlreadyInCheck = color == movingPiece.color }
		else { wasAlreadyInCheck = false }

		switch resultingBoard.state {
		case .check(let color) where color == movingPiece.color,
			 .checkmate(let color) where color == movingPiece.color:
			return KingSafetyViolation(
				attacker: checkingPiece(for: movingPiece.color, in: resultingPosition),
				kingWasAlreadyInCheck: wasAlreadyInCheck
			)
		default:
			return nil
		}
	}

	private func checkingPiece(for kingColor: Piece.Color, in position: Position) -> Piece? {
		guard let king = position.pieces.first(where: { $0.kind == .king && $0.color == kingColor }) else { return nil }
		let analysisBoard = Board(position: position)
		return position.pieces.first { piece in
			piece.color == kingColor.opposite
				&& analysisBoard.legalMoves(forPieceAt: piece.square).contains(king.square)
		}
	}

	private func kingSafetyExplanation(
		piece: Piece,
		from: Square,
		to: Square,
		violation: KingSafetyViolation
	) -> String {
		let attacker = violation.attacker.map {
			"my \($0.kind) on \($0.square.notation.uppercased())"
		} ?? "an attack"
		if violation.kingWasAlreadyInCheck {
			return "Your king is already in check from \(attacker). Moving your \(piece.kind) from \(from.notation.uppercased()) to \(to.notation.uppercased()) wouldn't get it out of check."
		}
		return "Moving your \(piece.kind) from \(from.notation.uppercased()) to \(to.notation.uppercased()) would expose your king to \(attacker)."
	}
	
	/// Applies a Stockfish UCI move (for example, `e7e8q`) to the shared board.
	func applyAIMove(_ uciMove: String) -> (san: String, start: Square, end: Square)? {
		let text = uciMove.lowercased()
		guard text.count == 4 || text.count == 5 else { return nil }
		let start = Square(String(text.prefix(2)))
		let end = Square(String(text.dropFirst(2).prefix(2)))
		guard board.legalMoves(forPieceAt: start).contains(end) else { return nil }

		let promotion: Piece.Kind
		if text.count == 5 {
			switch text.last {
			case "r": promotion = .rook
			case "b": promotion = .bishop
			case "n": promotion = .knight
			default: promotion = .queen
			}
		} else {
			promotion = .queen
		}
		let previousBoard = board
		guard var move = board.move(pieceAt: start, to: end) else { return nil }
		previousBoards.append(previousBoard)
		if case .promotion = board.state {
			move = board.completePromotion(of: move, to: promotion)
		}
		return (move.san, start, end)
	}

	/// Converts a Stockfish UCI move to SAN without changing the current position.
	func sanForUCIMove(_ uciMove: String) -> String? {
		let text = uciMove.lowercased()
		guard text.count == 4 || text.count == 5 else { return nil }
		let start = Square(String(text.prefix(2)))
		let end = Square(String(text.dropFirst(2).prefix(2)))
		guard board.legalMoves(forPieceAt: start).contains(end) else { return nil }

		let promotion: Piece.Kind
		if text.count == 5 {
			switch text.last {
			case "r": promotion = .rook
			case "b": promotion = .bishop
			case "n": promotion = .knight
			default: promotion = .queen
			}
		} else {
			promotion = .queen
		}

		var previewBoard = board
		guard var move = previewBoard.move(pieceAt: start, to: end) else { return nil }
		if case .promotion = previewBoard.state {
			move = previewBoard.completePromotion(of: move, to: promotion)
		}
		return move.san
	}

	func uciMove(forSAN san: String) -> String? {
		// In puzzles, spoken pawn captures may omit the starting file. Infer it
		// only when exactly one legal pawn can capture on the destination.
		if san.hasPrefix("x") {
			guard let expanded = inferredPawnCaptureSAN(san) else { return nil }
			return uciMove(forSAN: expanded)
		}
		guard let move = Move(san: san, position: board.position),
			  board.legalMoves(forPieceAt: move.start).contains(move.end) else { return nil }
		var uci = move.start.notation.lowercased() + move.end.notation.lowercased()
		if let promotedPiece = move.promotedPiece {
			uci += promotedPiece.kind.notation.lowercased()
		} else if move.piece.kind == .pawn,
				  move.end.rank.value == (move.piece.color == .white ? 8 : 1) {
			uci += "q"
		}
		return uci
	}

	private func inferredPawnCaptureSAN(_ san: String) -> String? {
		var core = san
		var checkSuffix = ""
		if core.hasSuffix("#") || core.hasSuffix("+") {
			checkSuffix = String(core.removeLast())
		}
		var promotionSuffix = ""
		if let equalsIndex = core.firstIndex(of: "=") {
			let pieceIndex = core.index(after: equalsIndex)
			guard pieceIndex < core.endIndex,
				  let piece = core[pieceIndex].uppercased().first,
				  "QRBN".contains(piece) else { return nil }
			promotionSuffix = "=\(piece)"
			core = String(core[..<equalsIndex])
		}
		guard core.count == 3, core.first == "x" else { return nil }
		let destination = String(core.dropFirst()).lowercased()
		let candidates = Square.allCases.filter { start in
			guard let piece = board.position.piece(at: start),
				  piece.kind == .pawn,
				  piece.color == board.position.sideToMove else { return false }
			return board.legalMoves(forPieceAt: start).contains {
				$0.notation.lowercased() == destination
			}
		}
		guard candidates.count == 1, let start = candidates.first else { return nil }
		let sourceFile = String(start.notation.prefix(1)).lowercased()
		return "\(sourceFile)x\(destination)\(promotionSuffix)\(checkSuffix)"
	}

	func checkmatesWithSAN(_ san: String) -> Bool {
		guard let move = Move(san: san, position: board.position),
			  board.legalMoves(forPieceAt: move.start).contains(move.end) else { return false }
		var preview = board
		guard let applied = preview.move(pieceAt: move.start, to: move.end) else { return false }
		if case .promotion = preview.state {
			preview.completePromotion(of: applied, to: move.promotedPiece?.kind ?? .queen)
		}
		if case .checkmate = preview.state { return true }
		return false
	}
	
	/// Converts SAN string to natural spoken phrasing
	func spokenRepresentation(for san: String) -> String {
		var notation = san
		var promotionName: String?
		if let equalsIndex = notation.firstIndex(of: "=") {
			let pieceIndex = notation.index(after: equalsIndex)
			if pieceIndex < notation.endIndex {
				let letter = String(notation[pieceIndex]).uppercased()
				promotionName = ["Q": "queen", "R": "rook", "B": "bishop", "N": "knight"][letter]
				if promotionName != nil {
					notation.removeSubrange(equalsIndex...pieceIndex)
				}
			}
		}
		if promotionName == nil {
			if notation.hasPrefix("O-O-O") { return "castles queenside" + spokenSuffix(for: notation) }
			if notation.hasPrefix("O-O") { return "castles kingside" + spokenSuffix(for: notation) }
			if let disambiguatedMove = spokenDisambiguatedPieceMove(for: notation) { return disambiguatedMove }
		}
		let suffix = spokenSuffix(for: notation)
		if notation.hasSuffix("#") || notation.hasSuffix("+") { notation.removeLast() }
		var text = notation
			.replacingOccurrences(of: "x", with: " takes ")
		
		if text.hasPrefix("N") { text = "Knight " + text.dropFirst() }
		else if text.hasPrefix("B") { text = "Bishop " + text.dropFirst() }
		else if text.hasPrefix("R") { text = "Rook " + text.dropFirst() }
		else if text.hasPrefix("Q") { text = "Queen " + text.dropFirst() }
		else if text.hasPrefix("K") { text = "King " + text.dropFirst() }
		else if text.first?.isLowercase == true {
			if let captureRange = text.range(of: " takes ") {
				let sourceFile = String(text[..<captureRange.lowerBound]).uppercased()
				let captureTarget = text[captureRange.upperBound...]
				text = "Pawn from \(sourceFile) takes \(captureTarget.uppercased())"
			} else {
				text = "Pawn to " + text
			}
		}
		
		let coordinateTokens = text.split(separator: " ", omittingEmptySubsequences: false).map { token in
			let value = String(token)
			let lowercased = value.lowercased()
			if lowercased.count == 2,
			   "abcdefgh".contains(lowercased.first!),
			   "12345678".contains(lowercased.last!) {
				return lowercased.uppercased()
			}
			return value
		}
		let moveText = coordinateTokens.joined(separator: " ")
		let promotionText = promotionName.map { " promotes to \($0)" } ?? ""
		return moveText + promotionText + suffix
	}

	private func spokenDisambiguatedPieceMove(for san: String) -> String? {
		guard let pieceLetter = san.first,
			  let pieceName = ["K": "King", "Q": "Queen", "R": "Rook", "B": "Bishop", "N": "Knight"][String(pieceLetter)] else {
			return nil
		}
		var notation = String(san.dropFirst())
		let suffix = spokenSuffix(for: notation)
		if notation.hasSuffix("#") || notation.hasSuffix("+") { notation.removeLast() }
		let isCapture = notation.contains("x")
		notation.removeAll { $0 == "x" }
		guard notation.count >= 3 else { return nil }
		let destination = String(notation.suffix(2)).lowercased()
		let destinationCharacters = Array(destination)
		guard destinationCharacters.count == 2,
			  "abcdefgh".contains(destinationCharacters[0]),
			  "12345678".contains(destinationCharacters[1]) else { return nil }
		let disambiguation = String(notation.dropLast(2))
		guard !disambiguation.isEmpty else { return nil }

		let originPhrase: String
		switch disambiguation.count {
		case 1:
			if "abcdefgh".contains(disambiguation.lowercased()) {
				originPhrase = "from \(disambiguation.uppercased())"
			} else if "12345678".contains(disambiguation) {
				originPhrase = "from rank \(disambiguation)"
			} else {
				return nil
			}
		case 2:
			let originCharacters = Array(disambiguation.lowercased())
			guard "abcdefgh".contains(originCharacters[0]),
				  "12345678".contains(originCharacters[1]) else { return nil }
			originPhrase = "from \(disambiguation.uppercased())"
		default:
			return nil
		}

		let action = isCapture ? "takes" : "to"
		return "\(pieceName) \(originPhrase) \(action) \(destination.uppercased())\(suffix)"
	}

	private func spokenSuffix(for san: String) -> String {
		if san.hasSuffix("#") { return " checkmate" }
		if san.hasSuffix("+") { return " check" }
		return ""
	}
}

extension ChessEngineManager {
	enum SpokenMoveMatch: Equatable {
		case play(String)
		case confirm(uci: String, phrase: String)
		case chooseOrigin(moves: [String], piece: String)
		case illegal(String)
		case unheard
	}

	func matchSpokenMove(_ readings: [String], matcher: SpokenMoveMatcher = .shared) -> SpokenMoveMatch {
		let legal = legalUCIMoves.compactMap { uci -> SpokenMoveCandidate? in
			let start = Square(String(uci.prefix(2)))
			let end = Square(String(uci.dropFirst(2).prefix(2)))
			guard let piece = board.position.piece(at: start) else { return nil }
			let captures = board.position.piece(at: end) != nil || (piece.kind == .pawn && start.file != end.file)
			return SpokenMoveCandidate(uci: uci, piece: String(describing: piece.kind), captures: captures)
		}
		var costs = [String: Double]()
		for (index, text) in readings.prefix(8).enumerated() {
			var matches = matcher.scores(for: text, candidates: legal)
			if let san = MoveParser.completeLegacySAN(text) {
				// Keep all equally exact origins for an underspecified move.
				matches = matches.filter { $0.value == 0 }
				if isLegalPlayerMove(san), let uci = uciMove(forSAN: san) {
					matches[uci] = 0
				} else if index == 0, matches.isEmpty {
					return .illegal(san)
				}
			}
			for (uci, distance) in matches {
				let cost = distance + Double(index) * SpokenMoveMatcher.alternativeCost
				costs[uci] = min(costs[uci] ?? .infinity, cost)
			}
		}
		let ranked = costs.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value < $1.value }
		guard let best = ranked.first else {
			print("[PARSER] Couldn't parse '\(readings.first ?? "none")'")
			if let first = readings.first, let san = MoveParser.completeLegacySAN(first) { return .illegal(san) }
			return .unheard
		}
		let uci = best.key
		let start = Square(String(uci.prefix(2)))
		guard let piece = board.position.piece(at: start), let san = sanForUCIMove(uci) else { return .unheard }
		print("[PARSER] Parsed '\(readings.first ?? "none")' as '\(san)' with error \(String(format:"%.03f", best.value))")
		let tiedOrigins = ranked.filter {
			$0.value == best.value && $0.key.dropFirst(2) == uci.dropFirst(2)
				&& board.position.piece(at: Square(String($0.key.prefix(2))))?.kind == piece.kind
		}
		let name = String(describing: piece.kind).capitalized
		if tiedOrigins.count > 1 { return .chooseOrigin(moves: tiedOrigins.map(\.key), piece: name) }
		if best.value <= SpokenMoveMatcher.automaticCost,
		   ranked.dropFirst().first.map({ $0.value - best.value > SpokenMoveMatcher.minimumLead }) ?? true {
			return .play(san)
		}
		let phrase: String
		if san.trimmingCharacters(in: CharacterSet(charactersIn: "+#")).count == 3, !san.contains("x"), !san.hasPrefix("O") {
			phrase = "\(name) to \(uci.suffix(2).uppercased())"
		} else {
			phrase = spokenRepresentation(for: san)
		}
		return .confirm(uci: uci, phrase: phrase)
	}
}
