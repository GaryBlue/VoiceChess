// From the repository root:
// swiftc VoiceChess/{MoveParser,SpokenMoveMatcher}.swift Tests/SpokenMoveMatcherChecks.swift -o /tmp/check-spoken-moves && /tmp/check-spoken-moves
import Foundation

@main
struct SpokenMoveMatcherChecks {
	static func main() {
		let url = URL(fileURLWithPath: "VoiceChess/Resources/cmudict.txt")
		let matcher = SpokenMoveMatcher(dictionaryURL: url)
		let moves = [
			SpokenMoveCandidate(uci: "a1a5", piece: "rook", captures: false),
			SpokenMoveCandidate(uci: "a1a4", piece: "rook", captures: false),
			SpokenMoveCandidate(uci: "b1c3", piece: "knight", captures: false),
			SpokenMoveCandidate(uci: "c1g5", piece: "bishop", captures: false),
			SpokenMoveCandidate(uci: "d1d5", piece: "queen", captures: true),
			SpokenMoveCandidate(uci: "e2e4", piece: "pawn", captures: false)
		]
		let examples = [
			("boot two-eighty-five", "a1a5"), ("boot 285", "a1a5"),
			("root to ay four", "a1a4"), ("nite too see three", "b1c3"),
			("fish up to gee five", "c1g5"), ("clean takes dee five", "d1d5"),
			("prawn two ee four", "e2e4")
		]
		for (text, expected) in examples {
			let scores = matcher.scores(for: text, candidates: moves)
			precondition(scores.min { $0.value < $1.value }?.key == expected, "\(text): \(scores)")
		}
		let uncertain = matcher.scores(for: "boot two-eighty-five", candidates: moves)["a1a5"]!
		precondition(uncertain > SpokenMoveMatcher.automaticCost)
		let exact = matcher.scores(for: "rook to A5", candidates: moves)["a1a5"]!
		precondition(exact + SpokenMoveMatcher.alternativeCost < uncertain)

		let secondRook = SpokenMoveCandidate(uci: "h5a5", piece: "rook", captures: false)
		let ambiguous = matcher.scores(for: "boot two-eighty-five", candidates: moves + [secondRook])
		precondition(ambiguous["a1a5"] == ambiguous["h5a5"])
		for text in ["buy me five coffees", "turn off the light", "good morning"] {
			precondition(matcher.scores(for: text, candidates: moves).isEmpty, text)
		}
		let colours = ["black", "white"]
		precondition(matcher.closestWord(to: "back", candidates: colours) { [$0] } == "black")
		precondition(matcher.closestWord(to: "wide", candidates: colours) { [$0] } == "white")
		let pieces = ["pawn", "knight", "bishop", "rook", "queen", "king"]
		precondition(matcher.closestWord(to: "nights", candidates: pieces) { [$0, $0 + "s"] } == "knight")
		precondition(matcher.closestWord(to: "prawns", candidates: pieces) { [$0, $0 + "s"] } == "pawn")
		precondition(matcher.closestWord(to: "unrelated", candidates: pieces) { [$0, $0 + "s"] } == nil)
		precondition(matcher.closestWord(to: "night", candidates: ["knight", "nite"]) { [$0] } == nil)
		print("Spoken move matching checks passed.")
	}
}
