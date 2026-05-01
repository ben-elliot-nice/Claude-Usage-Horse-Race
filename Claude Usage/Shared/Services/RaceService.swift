// Claude Usage/Shared/Services/RaceService.swift
import Foundation
import Combine

/// Manages push (publishing local cost burn) and poll (fetching standings)
/// for the horse race feature. Completely independent of other app services.
@MainActor
final class RaceService: ObservableObject {
    static let shared = RaceService()

    // MARK: - Published State

    @Published var standings: RaceStandings?
    @Published var lastError: String?
    @Published var lastPollDate: Date?

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
              RaceSettings.shared.raceURL != nil else { return }
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

    // MARK: - Registration

    func register() async {
        guard let urlString = RaceSettings.shared.raceURL,
              let baseURL = URL(string: urlString) else { return }

        let payload: [String: Any] = [
            "id": RaceSettings.shared.participantID,
            "name": RaceSettings.shared.participantName,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }

        let endpoint = baseURL.appendingPathComponent("register")
        var request = URLRequest(url: endpoint)
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
            // Registration failure is non-fatal — will retry on next start()
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

    // MARK: - Push

    func push() async {
        guard let urlString = RaceSettings.shared.raceURL,
              let baseURL = URL(string: urlString) else { return }

        guard let (usedCents, limitCents) = resolveCostData() else { return }

        let payload: [String: Any] = [
            "id": RaceSettings.shared.participantID,
            "name": RaceSettings.shared.participantName,
            "cost_used_cents": usedCents,
            "cost_limit_cents": limitCents,
            "updated_at": Self.iso8601Formatter.string(from: Date())
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }

        let endpoint = baseURL.appendingPathComponent("participant")
        var request = URLRequest(url: endpoint)
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

    // MARK: - Poll

    func poll() async {
        guard let urlString = RaceSettings.shared.raceURL,
              let baseURL = URL(string: urlString) else { return }

        let endpoint = baseURL.appendingPathComponent("standings")
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 10

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                lastError = "Poll failed: bad status"
                return
            }
            let decoded = try decoder.decode(RaceStandings.self, from: data)
            standings = decoded
            lastError = nil
            lastPollDate = Date()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Cost Data Resolution

    /// Enterprise accounts report utilization via ClaudeUsage.effectiveSessionPercentage
    /// (the `utilization` field from the extra_usage API block — already a percentage, 0–100).
    /// This is the authoritative race metric — use it directly rather than deriving from
    /// cost amounts, which can diverge from utilization.
    ///
    /// We encode it as basis points out of 10000 so the server computes the correct
    /// percentage: e.g. 42.3% → cost_used=4230, cost_limit=10000.
    ///
    /// Fallback: console APIUsage credits (non-enterprise accounts).
    private func resolveCostData() -> (usedCents: Int, limitCents: Int)? {
        let profile = ProfileManager.shared.activeProfile

        // Primary: enterprise utilization (authoritative % from extra_usage API block)
        if profile?.connectionType == .enterprise,
           let usage = profile?.claudeUsage {
            let basisPoints = Int(usage.effectiveSessionPercentage * 100)
            return (usedCents: basisPoints, limitCents: 10000)
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
