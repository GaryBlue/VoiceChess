import Foundation

struct MoveParser {
	private static let numberWords = [
		"one": "1", "won": "1", "two": "2", "to": "2", "too": "2",
		"three": "3", "four": "4", "for": "4", "five": "5",
		"six": "6", "seven": "7", "eight": "8", "ate": "8"
	]

	static let fileWords = [
		"a": "a", "ay": "a", "alpha": "a",
		"b": "b", "be": "b", "bee": "b", "bravo": "b",
		"c": "c", "sea": "c", "see": "c", "charlie": "c",
		"d": "d", "dee": "d", "delta": "d",
		"e": "e", "ee": "e", "echo": "e",
		"f": "f", "eff": "f", "ef": "f", "foxtrot": "f",
		"g": "g", "gee": "g", "golf": "g",
		"jay": "j", "aitch": "h", "h": "h", "hotel": "h"
	]
	
	private static let pieceWords = [
		"pawn": "",
		"king": "K", "queen": "Q", "rook": "R", "bishop": "B",
		"knight": "N", "night": "N"
	]
	// Player vocabulary. Recognition errors are handled by the phonetic matcher.
	private static let contextualPieceAliases = [
		"castle": "rook", "tower": "rook", "horse": "knight"
	]
	private static let promotionVerbs: Set<String> = ["promote", "promotes", "promoting", "promotion"]
	private static let promotionPieceWords = [
		"queen": "Q", "rook": "R", "bishop": "B", "knight": "N", "night": "N"
	]

	static func parseSan(from text: String) -> String {
		let tokens = text.lowercased().split { !$0.isLetter && !$0.isNumber }
		var words = tokens.map(String.init)
		for index in words.indices {
			if let piece = contextualPieceAliases[words[index]],
			   isPieceMovePhrase(after: words.dropFirst(index + 1)) {
				words[index] = piece
			}
		}
		let promotion = extractPromotion(from: &words)
		
		//if let destination = coordinate(from: words) { return destination }
		//if let destination = coordinate(from: words), words.contains(where: { fileWords[$0] != nil }) { return destination }
		//if let digit = words.last(where: { "12345678".contains($0) }), digit == "4" {
		//	return "e4"
		//}

		let compact = words.joined()
		switch compact {
		case "before": return "b4"
		case "castlekingside", "castleskingside", "castles", "oo": return "O-O"
		case "castlequeenside", "castlesqueenside", "ooo": return "O-O-O"
		default: break
		}

		var hasFile = false
		var san = ""
		for word in words {
			if let piece = pieceWords[word] { san += piece }
			else if let number = numberWords[word] { if hasFile { san += number } }
			else if let file = fileWords[word] { san += file; hasFile = true }
			else if word == "takes" || word == "take" || word == "capture" { san += "x" }
			else if word.count == 2, let first = word.first, "abcdefgh".contains(first),
				let last = word.last, "12345678".contains(last) { san += word }
		}
		return san + (promotion ?? "")
	}

	private static func extractPromotion(from words: inout [String]) -> String? {
		guard let verbIndex = words.firstIndex(where: promotionVerbs.contains),
			  let pieceIndex = words.indices.first(where: {
				$0 > verbIndex && promotionPieceWords[words[$0]] != nil
			  }),
			  let promotionPiece = promotionPieceWords[words[pieceIndex]] else { return nil }
		words.removeSubrange(verbIndex...pieceIndex)
		return "=\(promotionPiece)"
	}

	private static func isPieceMovePhrase(after words: ArraySlice<String>) -> Bool {
		let words = Array(words)
		guard let first = words.first else { return false }
		if isSquareAtStart(words) { return true }
		if ["to", "takes", "take", "capture"].contains(first) {
			return containsSquare(in: words.dropFirst())
		}
		if first == "from", let toIndex = words.firstIndex(of: "to") {
			return containsSquare(in: words.dropFirst(toIndex + 1))
		}
		return false
	}

	private static func isSquareAtStart(_ words: [String]) -> Bool {
		guard let first = words.first else { return false }
		if first.count == 2,
		   let file = first.first, "abcdefgh".contains(file),
		   let rank = first.last, "12345678".contains(rank) { return true }
		return words.count > 1
			&& fileWords[first] != nil
			&& numberWords[words[1]].flatMap(Int.init).map { (1...8).contains($0) } == true
	}

	private static func containsSquare(in words: ArraySlice<String>) -> Bool {
		let words = Array(words)
		guard !words.isEmpty else { return false }
		for index in words.indices {
			if isSquareAtStart(Array(words[index...])) { return true }
		}
		return false
	}
}

extension MoveParser {
	// Keep existing castling, promotion and source-qualified phrases, but never
	// treat the scraps left by ignoring unknown words as an exact move.
	static func completeLegacySAN(_ text: String) -> String? {
		let ranks = ["one", "two", "three", "four", "five", "six", "seven", "eight"]
		let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }.map { token -> String in
			if token.count == 1, let rank = Int(token), (1...8).contains(rank) { return ranks[rank - 1] }
			return token == "captures" ? "takes" : String(token)
		}
		let syntax = ["before", "castle", "castles", "kingside", "queenside", "o", "oo", "ooo",
					  "from", "rank", "takes", "take", "capture", "move", "the", "please"]
		guard words.allSatisfy({ word in
			pieceWords[word] != nil || contextualPieceAliases[word] != nil || fileWords[word] != nil
				|| numberWords[word] != nil || promotionVerbs.contains(word) || syntax.contains(word)
				|| (word.count == 2 && "abcdefgh".contains(word.first!) && "12345678".contains(word.last!))
		}) else { return nil }
		let san = parseSan(from: words.joined(separator: " "))
		if san == "O-O" || san == "O-O-O" { return san }
		guard san.range(of: #"^[KQRBN]?[a-h]?[1-8]?x?[a-h][1-8](=[QRBN])?$"#,
						options: .regularExpression) != nil else { return nil }
		return san
	}
}
