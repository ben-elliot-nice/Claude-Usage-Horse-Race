// Claude Usage/MenuBar/RaceTabView.swift
import SwiftUI

/// The 🏇 Race tab shown in the popover.
/// Three states: not configured, live standings, error.
struct RaceTabView: View {
    @ObservedObject private var raceService = RaceService.shared
    let onOpenSettings: () -> Void
    @State private var showDetail = false

    var body: some View {
        Group {
            if ProfileManager.shared.activeProfile?.connectionType != .enterprise {
                enterpriseRequiredView
            } else if !RaceSettings.shared.raceEnabled || RaceSettings.shared.raceURL == nil {
                notConfiguredView
            } else if let error = raceService.lastError, raceService.standings == nil {
                errorView(message: error)
            } else {
                liveView
            }
        }
    }

    // MARK: - Enterprise Required

    private var enterpriseRequiredView: some View {
        VStack(spacing: 12) {
            Text("🏢")
                .font(.system(size: 32))

            Text("Enterprise account required.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary)

            Text("Connect an Enterprise Account in\nSettings to join a race.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)

            Button("Open Settings", action: onOpenSettings)
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.accentColor)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Color.accentColor.opacity(0.4), lineWidth: 1)
                )
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 14)
    }

    // MARK: - Not Configured

    private var notConfiguredView: some View {
        VStack(spacing: 12) {
            Text("🏇")
                .font(.system(size: 32))

            Text("No race configured.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary)

            Text("Add a race URL in\nSettings → Horse Race")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)

            Button("Open Settings", action: onOpenSettings)
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.accentColor)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Color.accentColor.opacity(0.4), lineWidth: 1)
                )
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 14)
    }

    // MARK: - Error

    private func errorView(message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 22))
                .foregroundColor(.orange)

            Text("Could not reach race server.")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.primary)

            Button("Retry") { raceService.refresh() }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.accentColor)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    // MARK: - Live

    private var liveView: some View {
        VStack(spacing: 0) {
            // Race header
            HStack {
                Text(raceSlugDisplay)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)

                Spacer()

                // Toggle between track and detail view
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showDetail.toggle()
                    }
                } label: {
                    Image(systemName: showDetail ? "flag.checkered" : "list.bullet")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help(showDetail ? "Show track" : "Show details")

                Button {
                    raceService.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 6)

            // Track lanes / detail list
            if let participants = raceService.standings?.participants, !participants.isEmpty {
                if showDetail {
                    // Detail list
                    VStack(spacing: 2) {
                        ForEach(participants) { participant in
                            HStack(spacing: 8) {
                                Text(participant.name)
                                    .font(.system(size: 11, weight: participant.name == RaceSettings.shared.participantName ? .bold : .medium))
                                    .foregroundColor(participant.isStale ? .secondary.opacity(0.4) : .primary)
                                    .frame(width: 52, alignment: .leading)
                                    .lineLimit(1)

                                Text(participant.formattedCostUsed)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(participant.isStale ? .secondary.opacity(0.4) : .primary)
                                    .frame(width: 48, alignment: .trailing)

                                Text("\(Int(participant.percentUsed))%")
                                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                                    .foregroundColor(participant.isStale ? .secondary.opacity(0.4) : .adaptiveGreen)
                                    .frame(width: 36, alignment: .trailing)

                                Spacer()

                                Text(participant.updatedAgoString)
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary.opacity(participant.isStale ? 0.4 : 0.7))
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 4)
                            .background(
                                participant.name == RaceSettings.shared.participantName
                                    ? Color.primary.opacity(0.04)
                                    : Color.clear
                            )
                        }
                    }
                    .padding(.bottom, 6)
                } else {
                    // Track view (existing)
                    VStack(spacing: 8) {
                        ForEach(participants) { participant in
                            HorseTrackRow(
                                participant: participant,
                                isYou: participant.name == RaceSettings.shared.participantName
                            )
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                }
            } else {
                Text("No participants yet.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            }

            // Footer
            if let pollDate = raceService.lastPollDate {
                Divider().padding(.horizontal, 16)
                Text("Updated \(relativeTime(from: pollDate))")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary.opacity(0.7))
                    .padding(.vertical, 5)
            }
        }
    }

    private var raceSlugDisplay: String {
        // Prefer the server-provided display name (e.g. "NICE-TEAM") over the UUID slug
        if let name = raceService.standings?.name, !name.isEmpty {
            return name
        }
        guard let url = RaceSettings.shared.raceURL,
              let last = URL(string: url)?.lastPathComponent,
              !last.isEmpty else {
            return raceService.standings?.raceSlug ?? "RACE"
        }
        return last
    }

    private func relativeTime(from date: Date) -> String {
        let s = Date().timeIntervalSince(date)
        if s < 5  { return "just now" }
        if s < 60 { return "\(Int(s))s ago" }
        return "\(Int(s/60))m ago"
    }
}

// MARK: - Single track lane

struct HorseTrackRow: View {
    let participant: RaceParticipant
    let isYou: Bool

    var body: some View {
        HStack(spacing: 8) {
            // Name label (fixed width, right-aligned)
            Text(participant.name)
                .font(.system(size: 10, weight: isYou ? .bold : .medium))
                .foregroundColor(participant.isStale ? .secondary.opacity(0.25) : (isYou ? .primary : .secondary))
                .frame(width: 42, alignment: .trailing)
                .lineLimit(1)

            // Track
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Dashed track line
                    DashedTrack(opacity: participant.isStale ? 0.05 : (isYou ? 0.18 : 0.1))

                    // Finish flag
                    Text("🏁")
                        .font(.system(size: 11))
                        .opacity(participant.isStale ? 0.2 : 1.0)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .offset(y: -1)

                    // Horse at % position
                    let horseX = max(0, min(geo.size.width - 18, geo.size.width * CGFloat(participant.percentUsed / 100.0) - 9))
                    Text("🐴")
                        .font(.system(size: 16))
                        .opacity(participant.isStale ? 0.25 : 1.0)
                        .grayscale(participant.isStale ? 1.0 : 0.0)
                        .offset(x: horseX, y: -1)
                        .help(participant.tooltipString)
                }
            }
            .frame(height: 18)
        }
    }
}

// MARK: - Dashed track line

struct DashedTrack: View {
    var opacity: Double

    var body: some View {
        GeometryReader { geo in
            Path { path in
                let y = geo.size.height / 2
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: geo.size.width, y: y))
            }
            .stroke(
                Color.primary.opacity(opacity),
                style: StrokeStyle(lineWidth: 1.5, dash: [3, 3])
            )
        }
    }
}
