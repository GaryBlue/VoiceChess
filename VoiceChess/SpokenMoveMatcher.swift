import Foundation

/// The phrase grammar describes what a player can say about one legal move.
/// Equivalent moves retain separate identities even when their phrases coincide.
struct SpokenMoveCandidate {
	let uci: String
	let piece: String
	let captures: Bool
	var origin: String { String(uci.prefix(2)) }
	var destination: String { String(uci.dropFirst(2).prefix(2)) }

	func phrases(includeOrigin: Bool, includePromotion: Bool) -> [String] {
		let square = destination
		var phrases = ["\(piece) to \(square)", "\(piece) \(square)"]
		if piece == "pawn" { phrases.append(square) }
		if captures { phrases.append("\(piece) takes \(square)") }
		if includeOrigin {
			for source in [origin, String(origin.prefix(1)), "rank " + origin.suffix(1)] {
				phrases.append("\(piece) from \(source) to \(square)")
				if captures { phrases.append("\(piece) from \(source) takes \(square)") }
			}
		}
		if piece == "king", origin.first == "e", ["c", "g"].contains(square.prefix(1)),
		   origin.last == square.last {
			phrases.append("castle " + (square.first == "g" ? "kingside" : "queenside"))
		}
		if uci.count == 5 {
			let promotions: [Character: String] = ["q": "queen", "r": "rook", "b": "bishop", "n": "knight"]
			guard let promoted = promotions[uci.last!] else { return [] }
			if includePromotion { return phrases.map { "\($0) promote to \(promoted)" } }
			if promoted != "queen" { return [] }
		}
		return phrases
	}
}

/// Weighted edit distance on phonemes. Word boundaries disappear after lookup,
/// so merged and split words use the same alignment as ordinary substitutions.
struct SpokenMoveMatcher {
	static let shared = SpokenMoveMatcher(dictionaryURL: Bundle.main.url(forResource: "cmudict", withExtension: "txt"))

	// Scores are edits per expected phoneme. Transcript rank is a small tie-breaker.
	static let maximumCost = 2.0//0.44
	static let automaticCost = 0.18
	static let minimumLead = 0.055
	static let alternativeCost = 0.04

	private let pronunciations: [Substring: Substring]
	private let numbers: NumberFormatter
	private let digitNames = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]

	init(dictionaryURL: URL?) {
		let contents = dictionaryURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
		var entries = [Substring: Substring]()
		entries.reserveCapacity(130_000)
		for line in contents.split(separator: "\n") {
			guard let space = line.firstIndex(of: " ") else { continue }
			let word = line[..<space]
			if word.last != ")" { entries[word] = line[line.index(after: space)...] }
		}
		pronunciations = entries
		numbers = NumberFormatter()
		numbers.numberStyle = .spellOut
		numbers.locale = Locale(identifier: "en_US")
	}

	private func tokens(_ text: String) -> [String] {
		// Split A5 into A and 5, while keeping a sequence such as 285 intact.
		text.lowercased().matches(of: #/[a-z]+|[0-9]+/#).map { String($0.output) }
	}

	private struct Phone {
		let symbol: Substring
		let family: Int
		var weak = false
		var gapCost: Int { weak ? 1 : 2 }

		func substitutionCost(for other: Phone) -> Int {
			if symbol == other.symbol { return 0 }
			return family == other.family ? 2 : 4
		}
	}

	private func phones(_ words: [String]) -> [Phone]? {
		var result = [Phone]()
		for word in words {
			// A file is read as a letter name, including when dictated in isolation.
			let spelling = word == "a" ? "ay" : word[...]
			let file = MoveParser.fileWords[word]
			guard let pronunciation = pronunciations[spelling] ?? file.flatMap({ pronunciations[$0[...]] }) else {
				return nil
			}
			var lastVowel: Int?
			for token in pronunciation.split(separator: " ") {
				if token.first == "#" { break }
				let symbol = token.prefix(while: { !$0.isNumber })
				guard let phone = Self.phonemes[symbol] else { return nil }
				result.append(phone)
				if token.last?.isNumber == true {
					// A later unstressed syllable is easier to insert or lose in dictation.
					if token.last == "0", let lastVowel {
						for index in (lastVowel + 1)..<result.count { result[index].weak = true }
					}
					lastVowel = result.count - 1
				}
			}
		}
		return result.isEmpty ? nil : result
	}

	private func readings(of words: [String]) -> [[Phone]] {
		// ASR may print a run of sounds as digits. Read each number as digits,
		// as a cardinal, or as a leading digit followed by a cardinal.
		var variants: [[String]] = [[]]
		for word in words {
			guard let value = Int(word) else {
				for i in variants.indices { variants[i].append(word) }
				continue
			}
			guard word.count <= 3 else { return [] }
			let digits = word.compactMap { $0.wholeNumberValue.map { digitNames[$0] } }
			var options = [digits]
			if word.count > 1, let cardinal = numbers.string(from: NSNumber(value: value)) {
				options.append(tokens(cardinal))
			}
			if word.count == 3, let tail = Int(word.dropFirst()),
			   let cardinal = numbers.string(from: NSNumber(value: tail)) {
				options.append([digits[0]] + tokens(cardinal))
			}
			variants = Array(variants.flatMap { prefix in options.map { prefix + $0 } }.prefix(12))
		}
		return variants.compactMap(phones)
	}

	// Related phonemes cost less to substitute. Each other edit costs one.
	private static let soundGroups = ["IY IH EY EH AE", "AH AA AO AW AY", "UH UW OW OY", "ER R",
									  "P B T D K G", "F V TH DH", "S Z SH ZH CH JH", "M N NG", "L W Y", "HH"]
	private static let phonemes: [Substring: Phone] = {
		var phones = [Substring: Phone]()
		for (group, sounds) in soundGroups.enumerated() {
			for symbol in sounds.split(separator: " ") {
				phones[symbol] = Phone(symbol: symbol, family: group)
			}
		}
		return phones
	}()

	private func distance(_ heard: [Phone], _ expected: [Phone]) -> Double {
		var row = [0]
		for target in expected { row.append(row.last! + target.gapCost) }
		let expectedWeight = row.last!
		for sound in heard {
			var diagonal = row[0]
			row[0] += sound.gapCost
			for (index, target) in expected.enumerated() {
				let above = row[index + 1]
				row[index + 1] = min(diagonal + sound.substitutionCost(for: target),
									 above + sound.gapCost, row[index] + target.gapCost)
				diagonal = above
			}
		}
		return Double(row[expected.count]) / Double(expectedWeight)
	}

	func scores(for text: String, candidates: [SpokenMoveCandidate]) -> [String: Double] {
		let words = tokens(text)
		guard !words.isEmpty, words.count <= 14 else { return [:] }
		let heard = readings(of: words)
		guard !heard.isEmpty else { return [:] }
		var phraseCosts = [String: Double]()
		var result = [String: Double]()
		for move in candidates {
			for phrase in move.phrases(includeOrigin: words.contains("from"),
									   includePromotion: words.contains { $0.hasPrefix("promot") }) {
				let cost: Double
				if let cached = phraseCosts[phrase] {
					cost = cached
				} else {
					guard let expected = readings(of: tokens(phrase)).first else { continue }
					let limit = expected.count < 5 ? 0.12 : Self.maximumCost
					let best = heard.filter { abs($0.count - expected.count) <= Int(2 * Double(expected.count) * limit) }
						.map { distance($0, expected) }.min() ?? .infinity
					cost = best <= limit ? best : .infinity
					phraseCosts[phrase] = cost
				}
				if cost.isFinite { result[move.uci] = min(result[move.uci] ?? .infinity, cost) }
			}
		}
		return result
	}
}
