// Claude Usage/Views/Settings/App/HorseRaceSettingsView.swift
import SwiftUI

struct HorseRaceSettingsView: View {

    // MARK: - Persisted state (mirrors RaceSettings)

    @State private var raceEnabled: Bool = RaceSettings.shared.raceEnabled
    @State private var serverBaseURL: String = RaceSettings.shared.serverBaseURL ?? ""
    @State private var participantName: String = RaceSettings.shared.participantName
    @State private var pushInterval: Double = RaceSettings.shared.pushInterval
    @State private var pollInterval: Double = RaceSettings.shared.pollInterval

    // MARK: - Participant name rename state (identity system)

    @State private var nameError: String? = nil
    @State private var previousName: String = RaceSettings.shared.participantName

    // MARK: - Create race state

    @State private var createRaceName: String = ""
    @State private var isCreating: Bool = false
    @State private var createFeedback: FeedbackState = .none

    // MARK: - Join race state

    @State private var joinRaceURL: String = ""
    @State private var isJoining: Bool = false
    @State private var joinFeedback: FeedbackState = .none

    // MARK: - Current race (refreshed after create/join/leave)

    @State private var currentRaceURL: String? = RaceSettings.shared.raceURL
    @State private var currentRaceName: String? = RaceSettings.shared.raceName
    @State private var urlCopied: Bool = false

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.section) {
                SettingsPageHeader(
                    title: "Horse Race",
                    subtitle: "Race your team to the Claude spend cap."
                )

                enableSection
                serverSection
                identitySection
                createSection
                joinSection
                if currentRaceURL != nil { currentRaceSection }
                timersSection
            }
            .padding()
        }
    }

    // MARK: - Enable

    private var enableSection: some View {
        SettingsSectionCard(
            title: "Race",
            subtitle: "Enable to start pushing your usage to the race."
        ) {
            SettingToggle(
                title: "Enable Horse Race",
                description: "Push your cost burn and poll standings on a timer.",
                isOn: $raceEnabled
            )
        }
        .onChange(of: raceEnabled) { _, newValue in
            RaceSettings.shared.raceEnabled = newValue
            RaceService.shared.restart()
        }
    }

    // MARK: - Server

    private var serverSection: some View {
        SettingsSectionCard(
            title: "Server",
            subtitle: "The root URL of your race server deployment."
        ) {
            TextField(
                "https://claude-usage-horse-race-staging.up.railway.app",
                text: $serverBaseURL
            )
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12, design: .monospaced))
            .onSubmit { saveServerBaseURL() }
        }
        .onChange(of: serverBaseURL) { _, _ in saveServerBaseURL() }
    }

    // MARK: - Identity

    private var identitySection: some View {
        SettingsSectionCard(
            title: "Your Name",
            subtitle: "How you appear on the race track."
        ) {
            VStack(alignment: .leading, spacing: 6) {
                TextField("e.g. Ben", text: $participantName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit { saveName() }

                if let error = nameError {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundColor(.red)
                }
            }
        }
        .onChange(of: participantName) { _, _ in nameError = nil }
    }

    // MARK: - Create

    private var createSection: some View {
        SettingsSectionCard(
            title: "Create a Race",
            subtitle: "Start a new race and share the URL with your team."
        ) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    TextField("e.g. NICE Team Sprint", text: $createRaceName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .disabled(isCreating)
                        .onSubmit { if canCreate { Task { await createRace() } } }

                    Button {
                        Task { await createRace() }
                    } label: {
                        if isCreating {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 60)
                        } else {
                            Text("Create")
                                .frame(width: 60)
                        }
                    }
                    .disabled(!canCreate || isCreating)
                }

                feedbackView(for: createFeedback)
            }
        }
    }

    private var canCreate: Bool {
        !createRaceName.trimmingCharacters(in: .whitespaces).isEmpty &&
        !serverBaseURL.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Join

    private var joinSection: some View {
        SettingsSectionCard(
            title: "Join a Race",
            subtitle: "Paste a URL shared by your team organiser."
        ) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    TextField("https://server/races/…", text: $joinRaceURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .disabled(isJoining)
                        .onSubmit { if canJoin { Task { await joinRace() } } }

                    Button {
                        Task { await joinRace() }
                    } label: {
                        if isJoining {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 60)
                        } else {
                            Text("Join")
                                .frame(width: 60)
                        }
                    }
                    .disabled(!canJoin || isJoining)
                }

                feedbackView(for: joinFeedback)
            }
        }
    }

    private var canJoin: Bool {
        !joinRaceURL.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Current Race

    private var currentRaceSection: some View {
        SettingsSectionCard(
            title: "Current Race",
            subtitle: nil
        ) {
            VStack(alignment: .leading, spacing: 10) {
                if let name = currentRaceName {
                    HStack {
                        Text("Race")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(name)
                            .font(.system(size: 11, weight: .medium))
                    }
                }

                if let url = currentRaceURL {
                    HStack(spacing: 6) {
                        Text(url)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer()

                        Button(urlCopied ? "Copied!" : "Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url, forType: .string)
                            urlCopied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                urlCopied = false
                            }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.accentColor)
                    }
                }

                Button("Leave Race") {
                    leaveRace()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundColor(.red)
            }
        }
    }

    // MARK: - Timers

    private var timersSection: some View {
        SettingsSectionCard(
            title: "Timers",
            subtitle: "How often to push your usage and poll standings."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Push every")
                        .font(.system(size: 12))
                        .foregroundColor(.primary)
                    Spacer()
                    Stepper(
                        "\(Int(pushInterval))s",
                        value: $pushInterval,
                        in: 10...300,
                        step: 10
                    )
                    .font(.system(size: 12))
                }

                HStack {
                    Text("Poll every")
                        .font(.system(size: 12))
                        .foregroundColor(.primary)
                    Spacer()
                    Stepper(
                        "\(Int(pollInterval))s",
                        value: $pollInterval,
                        in: 10...300,
                        step: 10
                    )
                    .font(.system(size: 12))
                }
            }
        }
        .onChange(of: pushInterval) { _, newValue in
            RaceSettings.shared.pushInterval = newValue
            RaceService.shared.restart()
        }
        .onChange(of: pollInterval) { _, newValue in
            RaceSettings.shared.pollInterval = newValue
            RaceService.shared.restart()
        }
    }

    // MARK: - Feedback helper

    @ViewBuilder
    private func feedbackView(for state: FeedbackState) -> some View {
        switch state {
        case .none:
            EmptyView()
        case .success(let msg):
            Text("✓ \(msg)")
                .font(.system(size: 10))
                .foregroundColor(.green)
        case .failure(let msg):
            Text("✗ \(msg)")
                .font(.system(size: 10))
                .foregroundColor(.red)
        }
    }

    // MARK: - Actions: Server

    private func saveServerBaseURL() {
        let trimmed = serverBaseURL.trimmingCharacters(in: .whitespaces)
        RaceSettings.shared.serverBaseURL = trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Actions: Create

    @MainActor
    private func createRace() async {
        let name = createRaceName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }

        isCreating = true
        createFeedback = .none

        do {
            let url = try await RaceService.shared.createRace(name: name)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url, forType: .string)
            createFeedback = .success("Race created. URL copied to clipboard.")
            createRaceName = ""
            refreshCurrentRace()
            try? await Task.sleep(for: .seconds(3))
            if case .success = createFeedback { createFeedback = .none }
        } catch {
            createFeedback = .failure(error.localizedDescription)
        }

        isCreating = false
    }

    // MARK: - Actions: Join

    @MainActor
    private func joinRace() async {
        let urlString = joinRaceURL.trimmingCharacters(in: .whitespaces)
        guard !urlString.isEmpty, let baseURL = URL(string: urlString) else {
            joinFeedback = .failure("Invalid URL.")
            return
        }

        isJoining = true
        joinFeedback = .none

        let endpoint = baseURL.appendingPathComponent("standings")
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                joinFeedback = .failure("Race not found or server unreachable.")
                isJoining = false
                return
            }

            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            decoder.dateDecodingStrategy = .iso8601
            let standings = try? decoder.decode(RaceStandings.self, from: data)

            RaceSettings.shared.raceURL = urlString
            RaceSettings.shared.raceName = standings?.name
            RaceService.shared.restart()
            joinFeedback = .success("Joined race.")
            joinRaceURL = ""
            refreshCurrentRace()
            try? await Task.sleep(for: .seconds(3))
            if case .success = joinFeedback { joinFeedback = .none }
        } catch {
            joinFeedback = .failure(error.localizedDescription)
        }

        isJoining = false
    }

    // MARK: - Actions: Leave

    private func leaveRace() {
        RaceSettings.shared.raceURL = nil
        RaceSettings.shared.raceName = nil
        RaceService.shared.stop()
        refreshCurrentRace()
    }

    // MARK: - Actions: Name (rename via identity system)

    private func saveName() {
        let trimmed = participantName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            participantName = previousName
            return
        }
        let old = previousName
        guard trimmed != old else { return }

        guard let urlString = RaceSettings.shared.raceURL,
              let baseURL = URL(string: urlString) else {
            RaceSettings.shared.participantName = trimmed
            previousName = trimmed
            return
        }

        let payload: [String: Any] = [
            "id": RaceSettings.shared.participantID,
            "old_name": old,
            "new_name": trimmed,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }

        var request = URLRequest(url: baseURL.appendingPathComponent("participant/rename"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 10

        Task {
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                await MainActor.run {
                    if let http = response as? HTTPURLResponse {
                        if http.statusCode == 200 {
                            RaceSettings.shared.participantName = trimmed
                            previousName = trimmed
                            nameError = nil
                        } else if http.statusCode == 409 {
                            nameError = "Name already taken"
                            participantName = old
                        } else {
                            RaceSettings.shared.participantName = trimmed
                            previousName = trimmed
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    RaceSettings.shared.participantName = trimmed
                    previousName = trimmed
                }
            }
        }
    }

    // MARK: - Helpers

    private func refreshCurrentRace() {
        currentRaceURL = RaceSettings.shared.raceURL
        currentRaceName = RaceSettings.shared.raceName
    }
}

// MARK: - Feedback State

private enum FeedbackState {
    case none
    case success(String)
    case failure(String)
}
