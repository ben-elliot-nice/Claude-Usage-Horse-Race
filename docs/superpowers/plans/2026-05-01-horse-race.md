# Horse Race Feature Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a horse race tab to the macOS menubar popover that shows team members' Claude API cost burn as horses on a track, synced via a shared remote API (proven locally with a Python debug server).

**Architecture:** A new `RaceService` singleton manages independent push (60s) and poll (30s) timers against a configurable race URL. The popover gains a two-tab layout (Usage / Race). A Python debug server proves the API contract before a production server is built.

**Tech Stack:** Swift/SwiftUI (macOS), XCTest, Python 3 (stdlib only for debug server), xcodeproj gem for programmatic Xcode project management.

---

## Worktree

All work is in the `feature/horse-race` worktree at:
```
/Users/Ben.Elliot/repos/claude-usage-horse-race-feature/horse-race/
```

All paths below are relative to that root unless stated otherwise.

## Build Verification Command

Use this throughout to verify the project compiles:
```bash
cd "/Users/Ben.Elliot/repos/claude-usage-horse-race-feature/horse-race"
xcodebuild build \
  -project "Claude Usage.xcodeproj" \
  -scheme "Claude Usage" \
  -destination "platform=macOS,arch=arm64" \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO \
  2>&1 | grep -E "^(error:|warning:|BUILD)" | tail -30
```
Expected success: `BUILD SUCCEEDED`

## Adding Swift Files to the Xcode Project

Every new Swift file must be registered with the Xcode project or it won't compile. Use the `xcodeproj` gem:

```bash
# Install once if needed
gem install xcodeproj 2>/dev/null || true

# Template — replace GROUP_PATH and FILE_PATH for each file
ruby - <<'RUBY'
require 'xcodeproj'
project = Xcodeproj::Project.open('Claude Usage.xcodeproj')
# Navigate to the group, creating subgroups as needed
group = project['Claude Usage']
# Add file reference
ref = group.new_file('relative/path/from/Claude Usage/File.swift')
# Add to main app target
target = project.targets.find { |t| t.name == 'Claude Usage' }
target.source_build_phase.add_file_reference(ref)
project.save
RUBY
```

---

## File Map

| File | Action | Responsibility |
|------|--------|---------------|
| `debug/debug_race_server.py` | Create | Python debug server — proves API contract |
| `Claude Usage/Shared/Models/RaceParticipant.swift` | Create | Data model: participant, standings, staleness |
| `Claude Usage/Shared/Storage/RaceSettings.swift` | Create | UserDefaults keys and defaults for race config |
| `Claude Usage/Shared/Services/RaceService.swift` | Create | Push/poll timers, standings state, manual refresh |
| `Claude Usage/MenuBar/RaceTabView.swift` | Create | Horse race popover tab (3 states: unconfigured, live, error) |
| `Claude Usage/Views/Settings/App/HorseRaceSettingsView.swift` | Create | Settings section for race URL, name, intervals |
| `Claude Usage/MenuBar/PopoverContentView.swift` | Modify | Add tab bar (Usage / Race), show RaceTabView |
| `Claude Usage/Views/SettingsView.swift` | Modify | Add `.horseRace` case to `SettingsSection`, route to `HorseRaceSettingsView` |
| `Claude Usage/App/AppDelegate.swift` | Modify | Start `RaceService` after setup |
| `Claude UsageTests/RaceParticipantTests.swift` | Create | Unit tests for model logic |
| `Claude UsageTests/RaceSettingsTests.swift` | Create | Unit tests for settings defaults/persistence |

---

## Task 1: Python Debug Server

**Files:**
- Create: `debug/debug_race_server.py`

This is standalone Python — no Xcode involvement. It proves the API contract before the Swift client is written.

- [ ] **Step 1: Create the debug server**

```python
# debug/debug_race_server.py
#!/usr/bin/env python3
"""
Horse Race Debug Server
Proves the API contract for the Claude Usage horse race feature.
In-memory state — resets on restart.

Usage:
    python3 debug/debug_race_server.py
    python3 debug/debug_race_server.py --port 9000
"""

import argparse
import json
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse

# In-memory store: { slug: { name: { name, cost_used_cents, cost_limit_cents, updated_at } } }
RACES: dict = {}


def sorted_participants(slug: str) -> list:
    """Return participants sorted by % used descending."""
    participants = list(RACES.get(slug, {}).values())
    def pct(p):
        limit = p["cost_limit_cents"]
        return p["cost_used_cents"] / limit if limit > 0 else 0
    return sorted(participants, key=pct, reverse=True)


class RaceHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print(f"[{datetime.now().strftime('%H:%M:%S')}] {fmt % args}")

    def send_json(self, status: int, data: dict):
        body = json.dumps(data, indent=2).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def parse_slug_and_action(self):
        """Parse /races/{slug}/participant or /races/{slug}/standings"""
        parts = urlparse(self.path).path.strip("/").split("/")
        # parts = ["races", slug, action]
        if len(parts) == 3 and parts[0] == "races":
            return parts[1], parts[2]
        return None, None

    def do_PUT(self):
        slug, action = self.parse_slug_and_action()
        if action != "participant":
            self.send_json(404, {"error": "Not found"})
            return

        length = int(self.headers.get("Content-Length", 0))
        try:
            body = json.loads(self.rfile.read(length))
        except json.JSONDecodeError:
            self.send_json(400, {"error": "Invalid JSON"})
            return

        required = {"name", "cost_used_cents", "cost_limit_cents", "updated_at"}
        if not required.issubset(body.keys()):
            self.send_json(400, {"error": f"Missing fields. Required: {required}"})
            return

        # Auto-create race if not exists
        if slug not in RACES:
            RACES[slug] = {}
            print(f"  → Created race '{slug}'")

        RACES[slug][body["name"]] = {
            "name": body["name"],
            "cost_used_cents": int(body["cost_used_cents"]),
            "cost_limit_cents": int(body["cost_limit_cents"]),
            "updated_at": body["updated_at"],
        }
        print(f"  → Updated '{body['name']}' in '{slug}': "
              f"{body['cost_used_cents']}/{body['cost_limit_cents']} cents")

        self.send_json(200, {"status": "ok"})

    def do_GET(self):
        slug, action = self.parse_slug_and_action()
        if action != "standings":
            self.send_json(404, {"error": "Not found"})
            return

        if slug not in RACES:
            # Return empty standings — race auto-creates on first PUT
            self.send_json(200, {"race_slug": slug, "participants": []})
            return

        self.send_json(200, {
            "race_slug": slug,
            "participants": sorted_participants(slug),
        })


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Horse Race Debug Server")
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()

    server = HTTPServer(("127.0.0.1", args.port), RaceHandler)
    print(f"Horse Race debug server running at http://localhost:{args.port}")
    print(f"Race URL format: http://localhost:{args.port}/races/YOUR-SLUG")
    print("Press Ctrl+C to stop.\n")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")
```

- [ ] **Step 2: Run the server and verify with curl**

```bash
cd "/Users/Ben.Elliot/repos/claude-usage-horse-race-feature/horse-race"
python3 debug/debug_race_server.py &
SERVER_PID=$!
sleep 0.5

# Push two participants
curl -s -X PUT http://localhost:8765/races/NICE-TEAM/participant \
  -H "Content-Type: application/json" \
  -d '{"name":"Alice","cost_used_cents":61500,"cost_limit_cents":100000,"updated_at":"2026-05-01T14:20:00Z"}' | python3 -m json.tool

curl -s -X PUT http://localhost:8765/races/NICE-TEAM/participant \
  -H "Content-Type: application/json" \
  -d '{"name":"Ben","cost_used_cents":42300,"cost_limit_cents":100000,"updated_at":"2026-05-01T14:23:00Z"}' | python3 -m json.tool

# Get standings (Alice should be first)
curl -s http://localhost:8765/races/NICE-TEAM/standings | python3 -m json.tool

kill $SERVER_PID
```

Expected — standings response:
```json
{
  "race_slug": "NICE-TEAM",
  "participants": [
    {"name": "Alice", "cost_used_cents": 61500, "cost_limit_cents": 100000, "updated_at": "..."},
    {"name": "Ben", "cost_used_cents": 42300, "cost_limit_cents": 100000, "updated_at": "..."}
  ]
}
```

- [ ] **Step 3: Commit**

```bash
cd "/Users/Ben.Elliot/repos/claude-usage-horse-race-feature/horse-race"
git add debug/debug_race_server.py
git commit -m "feat: Add horse race debug server (Python, in-memory)"
```

---

## Task 2: Data Model

**Files:**
- Create: `Claude Usage/Shared/Models/RaceParticipant.swift`
- Create: `Claude UsageTests/RaceParticipantTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// Claude UsageTests/RaceParticipantTests.swift
import XCTest
@testable import Claude_Usage

final class RaceParticipantTests: XCTestCase {

    func testPercentUsed_normal() {
        let p = RaceParticipant(
            name: "Alice",
            costUsedCents: 61500,
            costLimitCents: 100000,
            updatedAt: Date()
        )
        XCTAssertEqual(p.percentUsed, 61.5, accuracy: 0.001)
    }

    func testPercentUsed_zeroLimit() {
        let p = RaceParticipant(
            name: "Alice",
            costUsedCents: 100,
            costLimitCents: 0,
            updatedAt: Date()
        )
        XCTAssertEqual(p.percentUsed, 0.0)
    }

    func testIsStale_fresh() {
        let p = RaceParticipant(
            name: "Alice",
            costUsedCents: 100,
            costLimitCents: 100000,
            updatedAt: Date()
        )
        XCTAssertFalse(p.isStale)
    }

    func testIsStale_old() {
        let oldDate = Date().addingTimeInterval(-301) // 5min 1sec ago
        let p = RaceParticipant(
            name: "Alice",
            costUsedCents: 100,
            costLimitCents: 100000,
            updatedAt: oldDate
        )
        XCTAssertTrue(p.isStale)
    }

    func testFormattedCost() {
        let p = RaceParticipant(
            name: "Alice",
            costUsedCents: 61500,
            costLimitCents: 100000,
            updatedAt: Date()
        )
        // $615.00
        XCTAssertTrue(p.formattedCostUsed.contains("615"))
    }

    func testRaceStandings_decodable() throws {
        let json = """
        {
          "race_slug": "NICE-TEAM",
          "participants": [
            {
              "name": "Alice",
              "cost_used_cents": 61500,
              "cost_limit_cents": 100000,
              "updated_at": "2026-05-01T14:20:00Z"
            }
          ]
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        let standings = try decoder.decode(RaceStandings.self, from: json)

        XCTAssertEqual(standings.raceSlug, "NICE-TEAM")
        XCTAssertEqual(standings.participants.count, 1)
        XCTAssertEqual(standings.participants[0].name, "Alice")
        XCTAssertEqual(standings.participants[0].costUsedCents, 61500)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd "/Users/Ben.Elliot/repos/claude-usage-horse-race-feature/horse-race"
xcodebuild test \
  -project "Claude Usage.xcodeproj" \
  -scheme "Claude Usage" \
  -destination "platform=macOS,arch=arm64" \
  -only-testing "Claude UsageTests/RaceParticipantTests" \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO \
  2>&1 | grep -E "(error:|FAILED|PASSED|cannot find)" | head -20
```

Expected: errors about `RaceParticipant` type not found.

- [ ] **Step 3: Write the model**

```swift
// Claude Usage/Shared/Models/RaceParticipant.swift
import Foundation

/// A single participant in a horse race — their cost burn for the period.
struct RaceParticipant: Codable, Identifiable {
    var id: String { name }

    let name: String
    let costUsedCents: Int
    let costLimitCents: Int
    let updatedAt: Date

    /// Percentage of limit consumed (0–100).
    var percentUsed: Double {
        guard costLimitCents > 0 else { return 0 }
        return Double(costUsedCents) / Double(costLimitCents) * 100.0
    }

    /// True if the participant's data hasn't been updated in >5 minutes.
    var isStale: Bool {
        Date().timeIntervalSince(updatedAt) > 300
    }

    /// Human-readable cost, e.g. "$615.00"
    var formattedCostUsed: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: Double(costUsedCents) / 100.0)) ?? "$?"
    }

    /// "2m ago" style relative time string.
    var updatedAgoString: String {
        let seconds = Date().timeIntervalSince(updatedAt)
        if seconds < 60 { return "just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        return "\(hours)h ago"
    }

    /// Tooltip string shown on horse hover.
    var tooltipString: String {
        "\(name) · \(formattedCostUsed) · \(Int(percentUsed))% · \(updatedAgoString)"
    }
}

/// The full standings response from GET {raceUrl}/standings
struct RaceStandings: Codable {
    let raceSlug: String
    let participants: [RaceParticipant]
}
```

- [ ] **Step 4: Add both files to Xcode project**

```bash
cd "/Users/Ben.Elliot/repos/claude-usage-horse-race-feature/horse-race"
gem install xcodeproj 2>/dev/null | tail -1

ruby - <<'RUBY'
require 'xcodeproj'
project = Xcodeproj::Project.open('Claude Usage.xcodeproj')

# Add RaceParticipant.swift to main target under Shared/Models
models_group = project['Claude Usage']['Shared']['Models']
model_ref = models_group.new_file('Shared/Models/RaceParticipant.swift')
main_target = project.targets.find { |t| t.name == 'Claude Usage' }
main_target.source_build_phase.add_file_reference(model_ref)

# Add RaceParticipantTests.swift to test target
tests_group = project['Claude UsageTests']
test_ref = tests_group.new_file('../Claude UsageTests/RaceParticipantTests.swift')
test_target = project.targets.find { |t| t.name == 'Claude UsageTests' }
test_target.source_build_phase.add_file_reference(test_ref)

project.save
puts "Done — added RaceParticipant.swift and RaceParticipantTests.swift"
RUBY
```

- [ ] **Step 5: Run tests — expect pass**

```bash
cd "/Users/Ben.Elliot/repos/claude-usage-horse-race-feature/horse-race"
xcodebuild test \
  -project "Claude Usage.xcodeproj" \
  -scheme "Claude Usage" \
  -destination "platform=macOS,arch=arm64" \
  -only-testing "Claude UsageTests/RaceParticipantTests" \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO \
  2>&1 | grep -E "(error:|Test Suite|PASSED|FAILED)" | tail -10
```

Expected: `Test Suite 'RaceParticipantTests' passed`

- [ ] **Step 6: Commit**

```bash
cd "/Users/Ben.Elliot/repos/claude-usage-horse-race-feature/horse-race"
git add "Claude Usage/Shared/Models/RaceParticipant.swift" \
        "Claude UsageTests/RaceParticipantTests.swift" \
        "Claude Usage.xcodeproj/project.pbxproj"
git commit -m "feat: Add RaceParticipant and RaceStandings models"
```

---

## Task 3: Race Settings

**Files:**
- Create: `Claude Usage/Shared/Storage/RaceSettings.swift`
- Create: `Claude UsageTests/RaceSettingsTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// Claude UsageTests/RaceSettingsTests.swift
import XCTest
@testable import Claude_Usage

final class RaceSettingsTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Clear all race keys before each test
        let keys = ["raceEnabled", "raceURL", "raceParticipantName",
                    "racePushInterval", "racePollInterval", "raceActiveTab"]
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    func testDefaults() {
        XCTAssertFalse(RaceSettings.shared.raceEnabled)
        XCTAssertNil(RaceSettings.shared.raceURL)
        XCTAssertFalse(RaceSettings.shared.participantName.isEmpty)
        XCTAssertEqual(RaceSettings.shared.pushInterval, 60.0)
        XCTAssertEqual(RaceSettings.shared.pollInterval, 30.0)
    }

    func testSaveAndLoadRaceURL() {
        RaceSettings.shared.raceURL = "http://localhost:8765/races/TEST"
        XCTAssertEqual(RaceSettings.shared.raceURL, "http://localhost:8765/races/TEST")
    }

    func testSaveAndLoadEnabled() {
        RaceSettings.shared.raceEnabled = true
        XCTAssertTrue(RaceSettings.shared.raceEnabled)
    }

    func testSaveAndLoadParticipantName() {
        RaceSettings.shared.participantName = "Alice"
        XCTAssertEqual(RaceSettings.shared.participantName, "Alice")
    }

    func testSaveAndLoadPushInterval() {
        RaceSettings.shared.pushInterval = 120.0
        XCTAssertEqual(RaceSettings.shared.pushInterval, 120.0)
    }

    func testSaveAndLoadPollInterval() {
        RaceSettings.shared.pollInterval = 45.0
        XCTAssertEqual(RaceSettings.shared.pollInterval, 45.0)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd "/Users/Ben.Elliot/repos/claude-usage-horse-race-feature/horse-race"
xcodebuild test \
  -project "Claude Usage.xcodeproj" \
  -scheme "Claude Usage" \
  -destination "platform=macOS,arch=arm64" \
  -only-testing "Claude UsageTests/RaceSettingsTests" \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO \
  2>&1 | grep -E "(error:|cannot find)" | head -10
```

Expected: `RaceSettings` not found.

- [ ] **Step 3: Write the settings class**

```swift
// Claude Usage/Shared/Storage/RaceSettings.swift
import Foundation

/// Persists horse race configuration in UserDefaults.
/// Follows the same load/save pattern as SharedDataStore.
final class RaceSettings {
    static let shared = RaceSettings()

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let raceEnabled       = "raceEnabled"
        static let raceURL           = "raceURL"
        static let participantName   = "raceParticipantName"
        static let pushInterval      = "racePushInterval"
        static let pollInterval      = "racePollInterval"
    }

    // MARK: - Race Enabled

    var raceEnabled: Bool {
        get { defaults.bool(forKey: Keys.raceEnabled) }
        set { defaults.set(newValue, forKey: Keys.raceEnabled) }
    }

    // MARK: - Race URL (full URL including slug)

    var raceURL: String? {
        get { defaults.string(forKey: Keys.raceURL).flatMap { $0.isEmpty ? nil : $0 } }
        set { defaults.set(newValue ?? "", forKey: Keys.raceURL) }
    }

    // MARK: - Participant Name (defaults to hostname)

    var participantName: String {
        get {
            let stored = defaults.string(forKey: Keys.participantName) ?? ""
            if stored.isEmpty {
                return ProcessInfo.processInfo.hostName
                    .components(separatedBy: ".").first ?? "Unknown"
            }
            return stored
        }
        set { defaults.set(newValue, forKey: Keys.participantName) }
    }

    // MARK: - Timer Intervals

    var pushInterval: TimeInterval {
        get {
            let v = defaults.double(forKey: Keys.pushInterval)
            return v > 0 ? v : 60.0
        }
        set { defaults.set(newValue, forKey: Keys.pushInterval) }
    }

    var pollInterval: TimeInterval {
        get {
            let v = defaults.double(forKey: Keys.pollInterval)
            return v > 0 ? v : 30.0
        }
        set { defaults.set(newValue, forKey: Keys.pollInterval) }
    }
}
```

- [ ] **Step 4: Add both files to Xcode project**

```bash
cd "/Users/Ben.Elliot/repos/claude-usage-horse-race-feature/horse-race"

ruby - <<'RUBY'
require 'xcodeproj'
project = Xcodeproj::Project.open('Claude Usage.xcodeproj')

storage_group = project['Claude Usage']['Shared']['Storage']
settings_ref = storage_group.new_file('Shared/Storage/RaceSettings.swift')
main_target = project.targets.find { |t| t.name == 'Claude Usage' }
main_target.source_build_phase.add_file_reference(settings_ref)

tests_group = project['Claude UsageTests']
test_ref = tests_group.new_file('../Claude UsageTests/RaceSettingsTests.swift')
test_target = project.targets.find { |t| t.name == 'Claude UsageTests' }
test_target.source_build_phase.add_file_reference(test_ref)

project.save
puts "Done"
RUBY
```

- [ ] **Step 5: Run tests — expect pass**

```bash
cd "/Users/Ben.Elliot/repos/claude-usage-horse-race-feature/horse-race"
xcodebuild test \
  -project "Claude Usage.xcodeproj" \
  -scheme "Claude Usage" \
  -destination "platform=macOS,arch=arm64" \
  -only-testing "Claude UsageTests/RaceSettingsTests" \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO \
  2>&1 | grep -E "(Test Suite|PASSED|FAILED|error:)" | tail -10
```

Expected: `Test Suite 'RaceSettingsTests' passed`

- [ ] **Step 6: Commit**

```bash
cd "/Users/Ben.Elliot/repos/claude-usage-horse-race-feature/horse-race"
git add "Claude Usage/Shared/Storage/RaceSettings.swift" \
        "Claude UsageTests/RaceSettingsTests.swift" \
        "Claude Usage.xcodeproj/project.pbxproj"
git commit -m "feat: Add RaceSettings (UserDefaults persistence)"
```

---

## Task 4: Race Service

**Files:**
- Create: `Claude Usage/Shared/Services/RaceService.swift`

No unit tests for this service — it makes live network calls and manages timers. Testability comes from end-to-end testing against the debug server in Task 1.

- [ ] **Step 1: Write the service**

```swift
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

    private var pushTimer: Timer?
    private var pollTimer: Timer?
    private let session = URLSession.shared
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .iso8601
        return d
    }()
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    // MARK: - Lifecycle

    func start() {
        guard RaceSettings.shared.raceEnabled,
              RaceSettings.shared.raceURL != nil else { return }
        schedulePushTimer()
        schedulePollTimer()
        // Immediate poll on start
        Task { await poll() }
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

    // MARK: - Timers

    private func schedulePushTimer() {
        pushTimer?.invalidate()
        let interval = RaceSettings.shared.pushInterval
        pushTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { await self?.push() }
        }
    }

    private func schedulePollTimer() {
        pollTimer?.invalidate()
        let interval = RaceSettings.shared.pollInterval
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { await self?.poll() }
        }
    }

    // MARK: - Push

    func push() async {
        guard let urlString = RaceSettings.shared.raceURL,
              let baseURL = URL(string: urlString) else { return }

        let costData = resolveCostData()
        guard let (usedCents, limitCents) = costData else { return }

        let payload: [String: Any] = [
            "name": RaceSettings.shared.participantName,
            "cost_used_cents": usedCents,
            "cost_limit_cents": limitCents,
            "updated_at": ISO8601DateFormatter().string(from: Date())
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
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                await MainActor.run { self.lastError = "Push failed: HTTP \(http.statusCode)" }
            }
        } catch {
            await MainActor.run { self.lastError = "Push error: \(error.localizedDescription)" }
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
                await MainActor.run { self.lastError = "Poll failed: bad status" }
                return
            }
            let decoded = try decoder.decode(RaceStandings.self, from: data)
            await MainActor.run {
                self.standings = decoded
                self.lastError = nil
                self.lastPollDate = Date()
            }
        } catch {
            await MainActor.run { self.lastError = error.localizedDescription }
        }
    }

    // MARK: - Cost Data Resolution

    /// Reads cost data from the active profile.
    /// Primary: APIUsage.currentSpendCents / (currentSpendCents + prepaidCreditsCents)
    /// Fallback: ClaudeUsage.costUsed / costLimit
    private func resolveCostData() -> (usedCents: Int, limitCents: Int)? {
        let profile = ProfileManager.shared.activeProfile

        if let api = profile?.apiUsage {
            let used = api.currentSpendCents
            let limit = api.currentSpendCents + api.prepaidCreditsCents
            if limit > 0 { return (used, limit) }
        }

        if let usage = profile?.claudeUsage,
           let costUsed = usage.costUsed,
           let costLimit = usage.costLimit,
           costLimit > 0 {
            return (Int(costUsed), Int(costLimit))
        }

        return nil
    }
}
```

- [ ] **Step 2: Add to Xcode project**

```bash
cd "/Users/Ben.Elliot/repos/claude-usage-horse-race-feature/horse-race"

ruby - <<'RUBY'
require 'xcodeproj'
project = Xcodeproj::Project.open('Claude Usage.xcodeproj')
services_group = project['Claude Usage']['Shared']['Services']
ref = services_group.new_file('Shared/Services/RaceService.swift')
target = project.targets.find { |t| t.name == 'Claude Usage' }
target.source_build_phase.add_file_reference(ref)
project.save
puts "Done"
RUBY
```

- [ ] **Step 3: Build to verify compilation**

```bash
cd "/Users/Ben.Elliot/repos/claude-usage-horse-race-feature/horse-race"
xcodebuild build \
  -project "Claude Usage.xcodeproj" \
  -scheme "Claude Usage" \
  -destination "platform=macOS,arch=arm64" \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO \
  2>&1 | grep -E "^(error:|BUILD)" | tail -10
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Commit**

```bash
cd "/Users/Ben.Elliot/repos/claude-usage-horse-race-feature/horse-race"
git add "Claude Usage/Shared/Services/RaceService.swift" \
        "Claude Usage.xcodeproj/project.pbxproj"
git commit -m "feat: Add RaceService (push/poll timers, standings state)"
```

---

## Task 5: Race Tab UI

**Files:**
- Create: `Claude Usage/MenuBar/RaceTabView.swift`

- [ ] **Step 1: Write the view**

```swift
// Claude Usage/MenuBar/RaceTabView.swift
import SwiftUI

/// The 🏇 Race tab shown in the popover.
/// Three states: not configured, live standings, error.
struct RaceTabView: View {
    @ObservedObject private var raceService = RaceService.shared
    let onOpenSettings: () -> Void

    var body: some View {
        Group {
            if !RaceSettings.shared.raceEnabled || RaceSettings.shared.raceURL == nil {
                notConfiguredView
            } else if let error = raceService.lastError, raceService.standings == nil {
                errorView(message: error)
            } else {
                liveView
            }
        }
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

            // Track lanes
            if let participants = raceService.standings?.participants, !participants.isEmpty {
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
                Text("Updated \(relativeTime(from: pollDate)) · hover for details")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary.opacity(0.7))
                    .padding(.vertical, 5)
            }
        }
    }

    private var raceSlugDisplay: String {
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
                .foregroundColor(participant.isStale ? .secondary.opacity(0.3) : (isYou ? .primary : .secondary))
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
```

- [ ] **Step 2: Add to Xcode project**

```bash
cd "/Users/Ben.Elliot/repos/claude-usage-horse-race-feature/horse-race"

ruby - <<'RUBY'
require 'xcodeproj'
project = Xcodeproj::Project.open('Claude Usage.xcodeproj')
menubar_group = project['Claude Usage']['MenuBar']
ref = menubar_group.new_file('MenuBar/RaceTabView.swift')
target = project.targets.find { |t| t.name == 'Claude Usage' }
target.source_build_phase.add_file_reference(ref)
project.save
puts "Done"
RUBY
```

- [ ] **Step 3: Build to verify compilation**

```bash
cd "/Users/Ben.Elliot/repos/claude-usage-horse-race-feature/horse-race"
xcodebuild build \
  -project "Claude Usage.xcodeproj" \
  -scheme "Claude Usage" \
  -destination "platform=macOS,arch=arm64" \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO \
  2>&1 | grep -E "^(error:|BUILD)" | tail -10
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Commit**

```bash
cd "/Users/Ben.Elliot/repos/claude-usage-horse-race-feature/horse-race"
git add "Claude Usage/MenuBar/RaceTabView.swift" \
        "Claude Usage.xcodeproj/project.pbxproj"
git commit -m "feat: Add RaceTabView (horse track UI, 3 states)"
```

---

## Task 6: Horse Race Settings View

**Files:**
- Create: `Claude Usage/Views/Settings/App/HorseRaceSettingsView.swift`

- [ ] **Step 1: Write the settings view**

```swift
// Claude Usage/Views/Settings/App/HorseRaceSettingsView.swift
import SwiftUI

struct HorseRaceSettingsView: View {
    @State private var raceEnabled: Bool = RaceSettings.shared.raceEnabled
    @State private var raceURL: String = RaceSettings.shared.raceURL ?? ""
    @State private var participantName: String = RaceSettings.shared.participantName
    @State private var pushInterval: Double = RaceSettings.shared.pushInterval
    @State private var pollInterval: Double = RaceSettings.shared.pollInterval

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
                    TextField("e.g. Ben", text: $participantName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .onSubmit {
                            RaceSettings.shared.participantName = participantName
                        }
                }
                .onChange(of: participantName) { _, newValue in
                    RaceSettings.shared.participantName = newValue
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
}
```

- [ ] **Step 2: Add to Xcode project**

```bash
cd "/Users/Ben.Elliot/repos/claude-usage-horse-race-feature/horse-race"

ruby - <<'RUBY'
require 'xcodeproj'
project = Xcodeproj::Project.open('Claude Usage.xcodeproj')
app_group = project['Claude Usage']['Views']['Settings']['App']
ref = app_group.new_file('Views/Settings/App/HorseRaceSettingsView.swift')
target = project.targets.find { |t| t.name == 'Claude Usage' }
target.source_build_phase.add_file_reference(ref)
project.save
puts "Done"
RUBY
```

- [ ] **Step 3: Build to verify**

```bash
cd "/Users/Ben.Elliot/repos/claude-usage-horse-race-feature/horse-race"
xcodebuild build \
  -project "Claude Usage.xcodeproj" \
  -scheme "Claude Usage" \
  -destination "platform=macOS,arch=arm64" \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO \
  2>&1 | grep -E "^(error:|BUILD)" | tail -10
```

- [ ] **Step 4: Commit**

```bash
cd "/Users/Ben.Elliot/repos/claude-usage-horse-race-feature/horse-race"
git add "Claude Usage/Views/Settings/App/HorseRaceSettingsView.swift" \
        "Claude Usage.xcodeproj/project.pbxproj"
git commit -m "feat: Add HorseRaceSettingsView"
```

---

## Task 7: Wire Up the Popover (Tab Bar)

**Files:**
- Modify: `Claude Usage/MenuBar/PopoverContentView.swift`

Adds a two-tab layout at the top of the popover. `Usage` tab shows the existing `SmartUsageDashboard`. `Race` tab shows `RaceTabView`.

- [ ] **Step 1: Add the tab enum and state**

In `PopoverContentView.swift`, add immediately after the opening `import SwiftUI` / `import Charts` block:

```swift
// MARK: - Popover Tab

private enum PopoverTab: String {
    case usage
    case race
}
```

In `PopoverContentView`, add a new `@State` property alongside the existing ones:

```swift
@State private var selectedTab: PopoverTab = {
    let raw = UserDefaults.standard.string(forKey: "popoverSelectedTab") ?? "usage"
    return PopoverTab(rawValue: raw) ?? .usage
}()
```

- [ ] **Step 2: Replace the `body` in `PopoverContentView`**

The existing `body` starts at `var body: some View {` and ends at `.frame(width: 280)`. Replace it entirely:

```swift
var body: some View {
    VStack(alignment: .leading, spacing: 0) {
        // Tab bar
        PopoverTabBar(selectedTab: $selectedTab)

        // Error / stale banners (only in usage tab)
        if selectedTab == .usage {
            if manager.hasCredentialError {
                StatusBannerView(
                    icon: "exclamationmark.triangle.fill",
                    message: "popover.banner.credentials_expired".localized,
                    color: .orange
                ) { onPreferences() }
            } else if manager.consecutiveRefreshFailures >= 3 {
                StatusBannerView(
                    icon: "arrow.clockwise.circle.fill",
                    message: String(format: "popover.banner.refresh_failed".localized, manager.consecutiveRefreshFailures),
                    color: .yellow
                ) { onRefresh() }
            } else if let lastRefresh = manager.lastSuccessfulRefreshTime,
                      Date().timeIntervalSince(lastRefresh) > 300 {
                let minutesAgo = Int(Date().timeIntervalSince(lastRefresh) / 60)
                StatusBannerView(
                    icon: "clock.fill",
                    message: String(format: "popover.banner.updated_ago".localized, minutesAgo),
                    color: .orange
                ) { onRefresh() }
            }
        }

        switch selectedTab {
        case .usage:
            // Existing usage content (unchanged)
            if profileManager.displayMode == .multi,
               let viewingProfile = manager.clickedProfileId.flatMap({ id in
                   profileManager.profiles.first(where: { $0.id == id })
               }) ?? profileManager.activeProfile {
                HStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .fill(Color.accentColor.opacity(0.15))
                            .frame(width: 20, height: 20)
                        Text(profileInitials(for: viewingProfile.name))
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .foregroundColor(.accentColor)
                    }
                    Text(viewingProfile.name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Spacer()
                    if viewingProfile.id == profileManager.activeProfile?.id {
                        Text("Active")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundColor(.accentColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.03)))
                .padding(.horizontal, 10)
                .padding(.top, 6)
            }

            SmartUsageDashboard(usage: displayUsage, apiUsage: displayAPIUsage)

        case .race:
            RaceTabView(onOpenSettings: onPreferences)
        }
    }
    .padding(.bottom, 8)
    .frame(width: 280)
    .background(VisualEffectBackground())
    .onChange(of: selectedTab) { _, newTab in
        UserDefaults.standard.set(newTab.rawValue, forKey: "popoverSelectedTab")
    }
}
```

- [ ] **Step 3: Add `PopoverTabBar` struct**

Add this new struct at the bottom of `PopoverContentView.swift`, before the closing of the file:

```swift
// MARK: - Popover Tab Bar

struct PopoverTabBar: View {
    @Binding var selectedTab: PopoverTab

    var body: some View {
        HStack(spacing: 0) {
            tabButton(label: "Usage", systemImage: "chart.bar.fill", tab: .usage)
            tabButton(label: "Race", systemImage: "flag.checkered", tab: .race)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private func tabButton(label: String, systemImage: String, tab: PopoverTab) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedTab = tab
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .medium))
                Text(tab == .race ? "🏇 \(label)" : label)
                    .font(.system(size: 11, weight: selectedTab == tab ? .semibold : .regular))
            }
            .foregroundColor(selectedTab == tab ? .primary : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selectedTab == tab ? Color.primary.opacity(0.08) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }
}

// Expose PopoverTab at file scope so SmartHeader can stay unchanged
private enum PopoverTab: String {
    case usage
    case race
}
```

**Note:** The `SmartHeader` at the top of the popover is removed and replaced by the tab bar. The refresh and settings buttons need to move into the tab bar or be kept in the header. Since `SmartHeader` includes the profile switcher, refresh, and settings gear — keep it above the tab bar. The `body` should therefore be:

```swift
var body: some View {
    VStack(alignment: .leading, spacing: 0) {
        // Header (profile switcher + refresh + settings) — always visible
        SmartHeader(
            usage: displayUsage,
            status: manager.status,
            isRefreshing: isRefreshing,
            onRefresh: {
                withAnimation(.easeInOut(duration: 0.3)) { isRefreshing = true }
                onRefresh()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    withAnimation(.easeInOut(duration: 0.3)) { isRefreshing = false }
                }
            },
            onManageProfiles: onPreferences,
            onPreferences: onPreferences,
            clickedProfileId: manager.clickedProfileId
        )

        PopoverDivider()

        // Tab bar
        PopoverTabBar(selectedTab: $selectedTab)

        PopoverDivider()

        // Tab content
        switch selectedTab {
        case .usage:
            // Banners
            if manager.hasCredentialError {
                StatusBannerView(
                    icon: "exclamationmark.triangle.fill",
                    message: "popover.banner.credentials_expired".localized,
                    color: .orange
                ) { onPreferences() }
            } else if manager.consecutiveRefreshFailures >= 3 {
                StatusBannerView(
                    icon: "arrow.clockwise.circle.fill",
                    message: String(format: "popover.banner.refresh_failed".localized, manager.consecutiveRefreshFailures),
                    color: .yellow
                ) { onRefresh() }
            } else if let lastRefresh = manager.lastSuccessfulRefreshTime,
                      Date().timeIntervalSince(lastRefresh) > 300 {
                let minutesAgo = Int(Date().timeIntervalSince(lastRefresh) / 60)
                StatusBannerView(
                    icon: "clock.fill",
                    message: String(format: "popover.banner.updated_ago".localized, minutesAgo),
                    color: .orange
                ) { onRefresh() }
            }

            // Profile tag (multi-profile mode)
            if profileManager.displayMode == .multi,
               let viewingProfile = manager.clickedProfileId.flatMap({ id in
                   profileManager.profiles.first(where: { $0.id == id })
               }) ?? profileManager.activeProfile {
                HStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .fill(Color.accentColor.opacity(0.15))
                            .frame(width: 20, height: 20)
                        Text(profileInitials(for: viewingProfile.name))
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .foregroundColor(.accentColor)
                    }
                    Text(viewingProfile.name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Spacer()
                    if viewingProfile.id == profileManager.activeProfile?.id {
                        Text("Active")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundColor(.accentColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.03)))
                .padding(.horizontal, 10)
                .padding(.top, 6)
            }

            SmartUsageDashboard(usage: displayUsage, apiUsage: displayAPIUsage)

        case .race:
            RaceTabView(onOpenSettings: onPreferences)
        }
    }
    .padding(.bottom, 8)
    .frame(width: 280)
    .background(VisualEffectBackground())
    .onChange(of: selectedTab) { _, newTab in
        UserDefaults.standard.set(newTab.rawValue, forKey: "popoverSelectedTab")
    }
}
```

Also add the `PopoverTab` enum and the `@State private var selectedTab` property before the `body`. The `PopoverTabBar` and `PopoverTab` should be defined outside `PopoverContentView` at file scope (not nested private enums inside two different structs).

**Concrete diff to apply:**

1. Add before the first `struct PopoverContentView`:
```swift
// MARK: - Popover Tab

enum PopoverTab: String {
    case usage
    case race
}
```

2. Add inside `PopoverContentView`, alongside existing `@State private var isRefreshing`:
```swift
@State private var selectedTab: PopoverTab = {
    let raw = UserDefaults.standard.string(forKey: "popoverSelectedTab") ?? "usage"
    return PopoverTab(rawValue: raw) ?? .usage
}()
```

3. Replace the entire `body` with the version above.

4. Add `PopoverTabBar` struct after `PopoverDivider` struct in the file.

- [ ] **Step 4: Build to verify**

```bash
cd "/Users/Ben.Elliot/repos/claude-usage-horse-race-feature/horse-race"
xcodebuild build \
  -project "Claude Usage.xcodeproj" \
  -scheme "Claude Usage" \
  -destination "platform=macOS,arch=arm64" \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO \
  2>&1 | grep -E "^(error:|BUILD)" | tail -10
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 5: Commit**

```bash
cd "/Users/Ben.Elliot/repos/claude-usage-horse-race-feature/horse-race"
git add "Claude Usage/MenuBar/PopoverContentView.swift"
git commit -m "feat: Add Usage/Race tab bar to popover"
```

---

## Task 8: Wire Up Settings

**Files:**
- Modify: `Claude Usage/Views/SettingsView.swift`

Add `horseRace` to `SettingsSection` and route to `HorseRaceSettingsView`.

- [ ] **Step 1: Add `horseRace` to the enum**

In `SettingsSection`, add `case horseRace` inside the `// Shared Settings` block (after `case mobileApp`):

```swift
case mobileApp
case horseRace   // ← add this
case popover
```

- [ ] **Step 2: Add title, icon, description**

In `var title: String`, add:
```swift
case .horseRace: return "Horse Race"
```

In `var icon: String`, add:
```swift
case .horseRace: return "flag.checkered"
```

In `var description: String` (if it exists), add:
```swift
case .horseRace: return "Race your team to the spend cap"
```

- [ ] **Step 3: Route to the view**

Find the `switch selectedSection` block in the detail view (around line 280) and add:
```swift
case .horseRace:
    HorseRaceSettingsView()
```

- [ ] **Step 4: Add to sidebar**

Find where sidebar items are listed (look for `.mobileApp` in the sidebar `ForEach` or list). Add `.horseRace` in the same group as `.mobileApp` and `.popover`:
```swift
sidebarItem(section: .horseRace)
```

- [ ] **Step 5: Build to verify**

```bash
cd "/Users/Ben.Elliot/repos/claude-usage-horse-race-feature/horse-race"
xcodebuild build \
  -project "Claude Usage.xcodeproj" \
  -scheme "Claude Usage" \
  -destination "platform=macOS,arch=arm64" \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO \
  2>&1 | grep -E "^(error:|BUILD)" | tail -10
```

- [ ] **Step 6: Commit**

```bash
cd "/Users/Ben.Elliot/repos/claude-usage-horse-race-feature/horse-race"
git add "Claude Usage/Views/SettingsView.swift"
git commit -m "feat: Add Horse Race settings section to sidebar"
```

---

## Task 9: Start RaceService on Launch

**Files:**
- Modify: `Claude Usage/App/AppDelegate.swift`

- [ ] **Step 1: Start the service after setup completes**

In `applicationDidFinishLaunching`, after the line `HeartbeatService.shared.start()`, add:

```swift
// Start horse race service if configured
RaceService.shared.start()
```

- [ ] **Step 2: Build to verify**

```bash
cd "/Users/Ben.Elliot/repos/claude-usage-horse-race-feature/horse-race"
xcodebuild build \
  -project "Claude Usage.xcodeproj" \
  -scheme "Claude Usage" \
  -destination "platform=macOS,arch=arm64" \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO \
  2>&1 | grep -E "^(error:|BUILD)" | tail -10
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
cd "/Users/Ben.Elliot/repos/claude-usage-horse-race-feature/horse-race"
git add "Claude Usage/App/AppDelegate.swift"
git commit -m "feat: Start RaceService on app launch"
```

---

## Task 10: End-to-End Smoke Test

Manual verification that the full stack works together.

- [ ] **Step 1: Start the debug server**

```bash
python3 "/Users/Ben.Elliot/repos/claude-usage-horse-race-feature/horse-race/debug/debug_race_server.py" &
echo "Server PID: $!"
```

- [ ] **Step 2: Seed some participants**

```bash
curl -s -X PUT http://localhost:8765/races/NICE-TEAM/participant \
  -H "Content-Type: application/json" \
  -d '{"name":"Alice","cost_used_cents":61500,"cost_limit_cents":100000,"updated_at":"2026-05-01T14:20:00Z"}' && \
curl -s -X PUT http://localhost:8765/races/NICE-TEAM/participant \
  -H "Content-Type: application/json" \
  -d '{"name":"Carol","cost_used_cents":18000,"cost_limit_cents":100000,"updated_at":"2026-05-01T14:19:00Z"}' && \
echo "Seeded."
```

- [ ] **Step 3: Build and run the app**

```bash
cd "/Users/Ben.Elliot/repos/claude-usage-horse-race-feature/horse-race"
xcodebuild build \
  -project "Claude Usage.xcodeproj" \
  -scheme "Claude Usage" \
  -destination "platform=macOS,arch=arm64" \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO \
  2>&1 | grep -E "^(error:|BUILD)"
```

Open Xcode and run the app, or use:
```bash
open -a "Claude Usage"
```

- [ ] **Step 4: Configure and verify**

1. Open Settings → Horse Race
2. Enable the toggle
3. Set Race URL: `http://localhost:8765/races/NICE-TEAM`
4. Set Your Name: `Ben`
5. Click the menu bar icon → switch to 🏇 Race tab
6. Verify Alice and Carol appear as horses on their tracks
7. Verify Ben's horse appears after the push timer fires (≤60s) or click ↺ refresh
8. Hover over a horse — tooltip should show name, cost, %, time ago
9. Verify a stale participant (manually set `updated_at` to 10min ago in a new PUT) appears greyed out

- [ ] **Step 5: Final commit**

```bash
cd "/Users/Ben.Elliot/repos/claude-usage-horse-race-feature/horse-race"
git log --oneline -10
```

All 9 feature commits should be visible. If smoke test revealed any issues, fix them with an additional commit before proceeding.
