// Claude Usage/Shared/Services/RaceService.swift
import Foundation
import Combine

/// Manages push/poll for all joined races and compiles deduplicated standings.
@MainActor
final class RaceService: ObservableObject {
    static let shared = RaceService()

    // MARK: - Published State

    @Published var allStandings: [String: RaceStandings] = [:]
    @Published var compiledStandings: [RaceParticipant] = []
    @Published var lastError: String?
    @Published var lastPollDate: Date?

    /// Compatibility shim for RaceTabView (Task 5) — returns the first available standings.
    /// Remove once RaceTabView is updated to use compiledStandings.
    var standings: RaceStandings? { allStandings.values.first }

    // MARK: - Private

    private static let iso8601Formatter = ISO8601DateFormatter()

    private var pushTimer: Timer?
    private var pollTimer: Timer?
    private let session = URLSession.shared
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: - Lifecycle

    func start() {
        guard RaceSettings.shared.raceEnabled,
              !RaceSettings.shared.raceEntries.isEmpty else { return }
        schedulePushTimer()
        schedulePollTimer()
        Task { await push() }
        Task { await poll() }
        Task { await register() }
    }

    func stop() {
        pushTimer?.invalidate()
        pollTimer?.invalidate()
        pushTimer = nil
        pollTimer = nil
    }

    func restart() {
        stop()
        start()
    }

    // MARK: - Manual Refresh

    func refresh() {
        Task { await poll() }
    }

    // MARK: - Race Creation

    /// Creates a new race on the server and adds it to raceEntries.
    func createRace(name: String) async throws -> String {
        guard let base = RaceSettings.shared.serverBaseURL,
              let serverURL = URL(string: base) else {
            throw RaceCreationError.noServerURL
        }

        let endpoint = serverURL.appendingPathComponent("races")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["name": name])
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw RaceCreationError.badResponse
        }
        guard http.statusCode == 201 else {
            throw RaceCreationError.serverError(http.statusCode)
        }

        let decoded = try decoder.decode(CreateRaceResponse.self, from: data)
        let raceURL = "\(base)/races/\(decoded.slug)"

        let entry = RaceEntry(url: raceURL, name: decoded.name)
        RaceSettings.shared.addRaceEntry(entry)
        restart()

        return raceURL
    }

    // MARK: - Registration

    func register() async {
        for entry in RaceSettings.shared.raceEntries {
            await registerInRace(url: entry.url)
        }
    }

    private func registerInRace(url: String) async {
        guard let baseURL = URL(string: url) else { return }

        let payload: [String: Any] = [
            "id": RaceSettings.shared.participantID,
            "name": RaceSettings.shared.participantName,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }

        var request = URLRequest(url: baseURL.appendingPathComponent("register"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 10

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return }
            if http.statusCode == 409 {
                lastError = "Name taken — choose a different name in Settings"
            } else if http.statusCode != 200 {
                lastError = "Registration failed: HTTP \(http.statusCode)"
            }
        } catch {
            // Non-fatal — will retry on next start()
        }
    }

    // MARK: - Timers

    private func schedulePushTimer() {
        pushTimer?.invalidate()
        let interval = RaceSettings.shared.pushInterval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { await self?.push() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pushTimer = timer
    }

    private func schedulePollTimer() {
        pollTimer?.invalidate()
        let interval = RaceSettings.shared.pollInterval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { await self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    // MARK: - Push (all races sequentially)

    func push() async {
        guard let costData = resolveCostData() else { return }
        let entries = RaceSettings.shared.raceEntries
        guard !entries.isEmpty else { return }

        for entry in entries {
            await pushToEntry(url: entry.url, costData: costData)
        }
    }

    private func pushToEntry(url: String, costData: (usedCents: Int, limitCents: Int)) async {
        guard let baseURL = URL(string: url) else { return }

        let payload: [String: Any] = [
            "id": RaceSettings.shared.participantID,
            "name": RaceSettings.shared.participantName,
            "cost_used_cents": costData.usedCents,
            "cost_limit_cents": costData.limitCents,
            "updated_at": Self.iso8601Formatter.string(from: Date())
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }

        var request = URLRequest(url: baseURL.appendingPathComponent("participant"))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 10

        do {
            let (_, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 403 {
                    lastError = "Name conflict — update your name in Settings"
                    pushTimer?.invalidate()
                    pushTimer = nil
                } else if http.statusCode != 200 {
                    lastError = "Push failed: HTTP \(http.statusCode)"
                }
            }
        } catch {
            lastError = "Push error: \(error.localizedDescription)"
        }
    }

    // MARK: - Poll (all races sequentially)

    func poll() async {
        let entries = RaceSettings.shared.raceEntries
        guard !entries.isEmpty else { return }

        var successCount = 0

        for entry in entries {
            guard let baseURL = URL(string: entry.url) else { continue }
            var request = URLRequest(url: baseURL.appendingPathComponent("standings"))
            request.timeoutInterval = 10

            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { continue }
                let decoded = try decoder.decode(RaceStandings.self, from: data)
                allStandings[entry.url] = decoded
                if let serverName = decoded.name, !serverName.isEmpty {
                    RaceSettings.shared.updateRaceEntryName(url: entry.url, name: serverName)
                }
                successCount += 1
            } catch {
                // Per-race failure — continue polling others
            }
        }

        compiledStandings = Self.compile(from: allStandings)
        lastPollDate = Date()
        lastError = successCount == 0 ? "Could not reach race server" : nil
    }

    // MARK: - Compile (static — testable without singleton)

    /// Deduplicates participants across all standings by display name,
    /// keeping each person's entry with the highest percentUsed.
    /// Returns sorted descending by percentUsed.
    nonisolated static func compile(from allStandings: [String: RaceStandings]) -> [RaceParticipant] {
        var best: [String: RaceParticipant] = [:]
        for standings in allStandings.values {
            for participant in standings.participants {
                if let existing = best[participant.name] {
                    if participant.percentUsed > existing.percentUsed {
                        best[participant.name] = participant
                    }
                } else {
                    best[participant.name] = participant
                }
            }
        }
        return best.values.sorted { $0.percentUsed > $1.percentUsed }
    }

    // MARK: - Cost Data Resolution

    private func resolveCostData() -> (usedCents: Int, limitCents: Int)? {
        let profile = ProfileManager.shared.activeProfile

        // Primary: enterprise monthly spend (used_credits already in cents)
        if profile?.connectionType == .enterprise,
           let usage = profile?.claudeUsage,
           let costUsed = usage.costUsed,
           let costLimit = usage.costLimit,
           costLimit > 0 {
            return (usedCents: Int(costUsed), limitCents: Int(costLimit))
        }

        // Fallback: console API credits
        if let api = profile?.apiUsage {
            let used = api.currentSpendCents
            let limit = api.currentSpendCents + api.prepaidCreditsCents
            if limit > 0 { return (used, limit) }
        }

        return nil
    }
}

enum RaceCreationError: LocalizedError {
    case noServerURL
    case badResponse
    case serverError(Int)

    var errorDescription: String? {
        switch self {
        case .noServerURL:           return "No server URL configured."
        case .badResponse:           return "Unexpected response from server."
        case .serverError(let code): return "Server returned HTTP \(code)."
        }
    }
}
