// Claude Usage/Views/Settings/App/HorseRaceSettingsView.swift
import SwiftUI

struct HorseRaceSettingsView: View {
    @State private var raceEnabled: Bool = RaceSettings.shared.raceEnabled
    @State private var raceURL: String = RaceSettings.shared.raceURL ?? ""
    @State private var participantName: String = RaceSettings.shared.participantName
    @State private var pushInterval: Double = RaceSettings.shared.pushInterval
    @State private var pollInterval: Double = RaceSettings.shared.pollInterval
    @State private var nameError: String? = nil
    @State private var previousName: String = RaceSettings.shared.participantName

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.section) {
                SettingsPageHeader(
                    title: "Horse Race",
                    subtitle: "Race your team to the Claude spend cap. Each participant's cost burn is shared via a remote URL."
                )

                // Enable toggle
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

                // Race URL
                SettingsSectionCard(
                    title: "Race URL",
                    subtitle: "Full URL including the race slug, e.g. http://localhost:8765/races/NICE-TEAM"
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("http://localhost:8765/races/NICE-TEAM", text: $raceURL)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .onSubmit { saveURL() }

                        Text("Changing this URL switches you to a different race immediately.")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
                .onChange(of: raceURL) { _, _ in saveURL() }

                // Participant name
                SettingsSectionCard(
                    title: "Your Name",
                    subtitle: "How you appear on the race track."
                ) {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("e.g. Ben", text: $participantName)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                            .onSubmit {
                                saveName()
                            }

                        if let error = nameError {
                            Text(error)
                                .font(.system(size: 10))
                                .foregroundColor(.red)
                        }
                    }
                }
                .onChange(of: participantName) { _, _ in
                    nameError = nil
                }

                // Intervals
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
            .padding()
        }
    }

    private func saveURL() {
        let trimmed = raceURL.trimmingCharacters(in: .whitespaces)
        RaceSettings.shared.raceURL = trimmed.isEmpty ? nil : trimmed
        RaceService.shared.restart()
    }

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
}
