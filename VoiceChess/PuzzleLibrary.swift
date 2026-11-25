import Foundation

struct ChessPuzzle: Decodable, Identifiable {
	let id: String
	let fen: String
	let moves: [String]
	let rating: Int
	let themes: String

	enum CodingKeys: String, CodingKey {
		case id
		case fen
		case moves
		case rating
		case themes
	}
}

private struct PuzzleCollection: Decodable {
	let puzzles: [String: [ChessPuzzle]]
}

enum PuzzleLibrary {
	static func puzzles(mateIn mate: Int) -> [ChessPuzzle] {
		(loadCollection()?.puzzles["mateIn\(mate)"] ?? []).sorted {
			if $0.rating != $1.rating { return $0.rating < $1.rating }
			return $0.id < $1.id
		}
	}

	static func puzzle(id: String) -> ChessPuzzle? {
		loadCollection()?.puzzles.values.flatMap { $0 }.first { $0.id == id }
	}

	private static func loadCollection() -> PuzzleCollection? {
		guard let url = Bundle.main.url(forResource: "mate_puzzles", withExtension: "json"),
			  let data = try? Data(contentsOf: url),
			  let collection = try? JSONDecoder().decode(PuzzleCollection.self, from: data) else { return nil }
		return collection
	}
}
