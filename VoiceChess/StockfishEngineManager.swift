import Foundation
import SFEngine

@MainActor
final class StockfishEngineManager {
	private enum EngineError: LocalizedError {
		case missingNetwork
		case startupTimedOut
		case searchTimedOut
		case noLegalMove
		case engine(String)

		var errorDescription: String? {
			switch self {
			case .missingNetwork: "Stockfish's evaluation network is missing from the app."
			case .startupTimedOut: "Stockfish did not finish starting in time."
			case .searchTimedOut: "Stockfish did not return a move in time."
			case .noLegalMove: "Stockfish found no legal move in this position."
			case .engine(let message): message
			}
		}
	}

	private var engine: SFEngine?
	private var isReady = false
	private var startupContinuation: CheckedContinuation<Void, Error>?
	private var moveContinuation: CheckedContinuation<String, Error>?
	private var startupTimeout: Task<Void, Never>?
	private var searchTimeout: Task<Void, Never>?

	func bestMove(fen: String, difficulty: ChessDifficulty) async throws -> String {
		try await startIfNeeded()
		return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
			moveContinuation = continuation
			engine?.sendCommand("setoption name Threads value 2")
			engine?.sendCommand("setoption name Skill Level value \(difficulty.skillLevel)")
			engine?.sendCommand("position fen \(fen)")
			engine?.sendCommand("go movetime \(difficulty.moveTimeMilliseconds)")
			searchTimeout = Task { [weak self] in
				do { try await Task.sleep(for: .seconds(12)) } catch { return }
				self?.finishSearch(.failure(EngineError.searchTimedOut))
			}
		}
	}

	private func startIfNeeded() async throws {
		if isReady { return }
		if startupContinuation != nil {
			throw EngineError.engine("Stockfish is already starting.")
		}
		guard let networkURL = Bundle.main.url(forResource: SFEngine.defaultNetworkFileName, withExtension: nil) else {
			throw EngineError.missingNetwork
		}

		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
			startupContinuation = continuation
			engine = SFEngine(networkFileURL: networkURL) { [weak self] line in
				Task { @MainActor [weak self] in self?.handleEngineLine(line) }
			}
			engine?.start()
			engine?.sendCommand("uci")
			startupTimeout = Task { [weak self] in
				do { try await Task.sleep(for: .seconds(20)) } catch { return }
				self?.finishStartup(.failure(EngineError.startupTimedOut))
			}
		}
	}

	private func handleEngineLine(_ line: String) {
		if line.hasPrefix("info string StockfishEmbedded error") {
			let error = EngineError.engine(line)
			if startupContinuation != nil {
				finishStartup(.failure(error))
			} else if moveContinuation != nil {
				finishSearch(.failure(error))
			}
		} else if line == "uciok" {
			engine?.sendCommand("isready")
		} else if line == "readyok" {
			isReady = true
			finishStartup(.success(()))
		} else if line.hasPrefix("bestmove ") {
			let parts = line.split(separator: " ")
			guard parts.count > 1, parts[1] != "(none)", parts[1] != "0000" else {
				finishSearch(.failure(EngineError.noLegalMove))
				return
			}
			finishSearch(.success(String(parts[1])))
		}
	}

	private func finishStartup(_ result: Result<Void, Error>) {
		startupTimeout?.cancel()
		startupTimeout = nil
		let continuation = startupContinuation
		startupContinuation = nil
		continuation?.resume(with: result)
	}

	private func finishSearch(_ result: Result<String, Error>) {
		searchTimeout?.cancel()
		searchTimeout = nil
		let continuation = moveContinuation
		moveContinuation = nil
		continuation?.resume(with: result)
	}
}
