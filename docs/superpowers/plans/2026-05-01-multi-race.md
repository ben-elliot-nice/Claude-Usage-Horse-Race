# Multi-Race + Compiled View Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace single-race storage with a list of `RaceEntry` values, push/poll all races simultaneously, and compile standings into a unified deduplicated track view.

**Architecture:** `RaceEntry` (new Codable model) replaces `raceURL`/`raceName` in `RaceSettings`. `RaceService` gains `allStandings: [String: RaceStandings]`, `compiledStandings: [RaceParticipant]`, and a static `compile(from:)` function. Push/poll iterate all entries sequentially. `HorseRaceSettingsView` shows a list of joined races with per-row remove buttons. `RaceTabView` consumes `compiledStandings`.

**Tech Stack:** Swift/SwiftUI, XCTest, UserDefaults (JSON-encoded list).

---

## Working Directory

All paths relative to the worktree root.

## Build Verification

```bash
xcodebuild build \
  -project "Claude Usage.xcodeproj" \
  -scheme "Claude Usage" \
  -destination "platform=macOS,arch=arm64" \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO \
  2>&1 | grep -E "^(error:|BUILD)" | tail -10
```

## Run Tests

```bash
xcodebuild test \
  -project "Claude Usage.xcodeproj" \
  -scheme "Claude Usage" \
  -destination "platform=macOS,arch=arm64" \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO \
  2>&1 | grep -E "(Test Suite|PASSED|FAILED|error:)" | tail -15
```

---

## File Map

| File | Action | What changes |
|------|--------|-------------|
| `Claude Usage/Shared/Models/RaceEntry.swift` | Create | New `RaceEntry: Codable, Identifiable` model |
| `Claude Usage/Shared/Storage/RaceSettings.swift` | Modify | Replace `raceURL`/`raceName` with `raceEntries: [RaceEntry]` + helpers + migration |
| `Claude Usage/Shared/Services/RaceService.swift` | Modify | Replace `standings` with `allStandings`/`compiledStandings`; update push/poll/register/start/createRace; add static `compile(from:)` |
| `Claude Usage/MenuBar/RaceTabView.swift` | Modify | Use `compiledStandings`; update not-configured check; update header |
| `Claude Usage/Views/Settings/App/HorseRaceSettingsView.swift` | Modify | Replace single currentRaceSection with joined-races list; update joinRace/leaveRace/saveName to use entries |
| `Claude UsageTests/RaceEntryTests.swift` | Create | Tests for RaceEntry encode/decode |
| `Claude UsageTests/RaceSettingsTests.swift` | Modify | Add raceEntries tests, migration test; remove raceURL/raceName tests |
| `Claude UsageTests/RaceServiceCompileTests.swift` | Create | Tests for `RaceService.compile(from:)` |

---

## Task 1: RaceEntry Model

**Files:**
- Create: `Claude Usage/Shared/Models/RaceEntry.swift`
- Create: `Claude UsageTests/RaceEntryTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// Claude UsageTests/RaceEntryTests.swift
import XCTest
@testable import Claude_Usage

final class RaceEntryTests: XCTestCase {

    func testRaceEntry_encodeDecode() throws {
        let id = UUID()
        let entry = RaceEntry(id: id, url: "https://server/races/abc", name: "NICE-TEAM")
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(RaceEntry.self, from: data)
        XCTAssertEqual(decoded.id, id)
        XCTAssertEqual(decoded.url, "https://server/races/abc")
        XCTAssertEqual(decoded.name, "NICE-TEAM")
    }

    func testRaceEntry_nameIsOptional() throws {
        let entry = RaceEntry(url: "https://server/races/abc")
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(RaceEntry.self, from: data)
        XCTAssertNil(decoded.name)
    }

    func testRaceEntry_defaultsUUID() {
        let entry = RaceEntry(url: "https://server/races/abc")
        XCTAssertNotNil(UUID(uuidString: entry.id.uuidString))
    }

    func testRaceEntry_equatable() {
        let id = UUID()
        let a = RaceEntry(id: id, url: "https://server/races/abc", name: "NICE")
        let b = RaceEntry(id: id, url: "https://server/races/abc", name: "NICE")
        XCTAssertEqual(a, b)
    }
}
```

- [ ] **Step 2: Run tests — expect failure**

```bash
xcodebuild test \
  -project "Claude Usage.xcodeproj" \
  -scheme "Claude Usage" \
  -destination "platform=macOS,arch=arm64" \
  -only-testing "Claude UsageTests/RaceEntryTests" \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO \
  2>&1 | grep -E "(error:|cannot find)" | head -5
```

Expected: `RaceEntry` not found.

- [ ] **Step 3: Write the model**

```swift
// Claude Usage/Shared/Models/RaceEntry.swift
import Foundation

/// A single race the client has joined.
/// Stored as a JSON-encoded list in UserDefaults.
struct RaceEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let url: String       // full race URL including slug
    var name: String?     // display name cached from server on first poll

    init(id: UUID = UUID(), url: String, name: String? = nil) {
        self.id = id
        self.url = url
        self.name = name
    }
}
```

- [ ] **Step 4: Run tests — expect pass**

```bash
xcodebuild test \
  -project "Claude Usage.xcodeproj" \
  -scheme "Claude Usage" \
  -destination "platform=macOS,arch=arm64" \
  -only-testing "Claude UsageTests/RaceEntryTests" \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO \
  2>&1 | grep -E "(Test Suite|PASSED|FAILED)" | tail -5
```

Expected: `Test Suite 'RaceEntryTests' passed`

- [ ] **Step 5: Commit**

```bash
git add "Claude Usage/Shared/Models/RaceEntry.swift" \
        "Claude UsageTests/RaceEntryTests.swift"
git commit -m "feat: Add RaceEntry model (Codable, Identifiable)"
```

---

## Task 2: RaceSettings — Replace Single Race with List

**Files:**
- Modify: `Claude Usage/Shared/Storage/RaceSettings.swift`
- Modify: `Claude UsageTests/RaceSettingsTests.swift`

- [ ] **Step 1: Write the failing tests**

Replace `Claude UsageTests/RaceSettingsTests.swift` entirely:

```swift
// Claude UsageTests/RaceSettingsTests.swift
import XCTest
@testable import Claude_Usage

final class RaceSettingsTests: XCTestCase {

    override func setUp() {
        super.setUp()
        let keys = ["raceEnabled", "raceParticipantName",
                    "racePushInterval", "racePollInterval",
                    "raceParticipantID", "raceServerBaseURL",
                    "raceEntries"]
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        // Also clear legacy keys for migration tests
        UserDefaults.standard.removeObject(forKey: "raceURL")
        UserDefaults.standard.removeObject(forKey: "raceCurrentRaceName")
    }

    // MARK: - Unchanged settings

    func testDefaults() {
        XCTAssertFalse(RaceSettings.shared.raceEnabled)
        XCTAssertFalse(RaceSettings.shared.participantName.isEmpty)
        XCTAssertEqual(RaceSettings.shared.pushInterval, 60.0)
        XCTAssertEqual(RaceSettings.shared.pollInterval, 30.0)
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

    func testParticipantID_generatedOnce() {
        UserDefaults.standard.removeObject(forKey: "raceParticipantID")
        let id1 = RaceSettings.shared.participantID
        let id2 = RaceSettings.shared.participantID
        XCTAssertNotNil(UUID(uuidString: id1))
        XCTAssertEqual(id1, id2)
    }

    func testServerBaseURL_defaultsNil() {
        XCTAssertNil(RaceSettings.shared.serverBaseURL)
    }

    func testServerBaseURL_saveAndLoad() {
        RaceSettings.shared.serverBaseURL = "https://example.com"
        XCTAssertEqual(RaceSettings.shared.serverBaseURL, "https://example.com")
    }

    // MARK: - raceEntries

    func testRaceEntries_defaultsEmpty() {
        XCTAssertTrue(RaceSettings.shared.raceEntries.isEmpty)
    }

    func testAddRaceEntry() {
        let entry = RaceEntry(url: "https://server/races/abc", name: "TEST")
        RaceSettings.shared.addRaceEntry(entry)
        XCTAssertEqual(RaceSettings.shared.raceEntries.count, 1)
        XCTAssertEqual(RaceSettings.shared.raceEntries[0].url, "https://server/races/abc")
        XCTAssertEqual(RaceSettings.shared.raceEntries[0].name, "TEST")
    }

    func testAddMultipleEntries() {
        RaceSettings.shared.addRaceEntry(RaceEntry(url: "https://server/races/a"))
        RaceSettings.shared.addRaceEntry(RaceEntry(url: "https://server/races/b"))
        XCTAssertEqual(RaceSettings.shared.raceEntries.count, 2)
    }

    func testRemoveRaceEntry() {
        let entry = RaceEntry(url: "https://server/races/abc")
        RaceSettings.shared.addRaceEntry(entry)
        RaceSettings.shared.removeRaceEntry(id: entry.id)
        XCTAssertTrue(RaceSettings.shared.raceEntries.isEmpty)
    }

    func testUpdateRaceEntryName() {
        let entry = RaceEntry(url: "https://server/races/abc")
        RaceSettings.shared.addRaceEntry(entry)
        RaceSettings.shared.updateRaceEntryName(url: "https://server/races/abc", name: "NICE-TEAM")
        XCTAssertEqual(RaceSettings.shared.raceEntries[0].name, "NICE-TEAM")
    }

    func testMigration_legacyRaceURL() {
        // Seed legacy single-race keys
        UserDefaults.standard.set("https://server/races/legacy", forKey: "raceURL")
        UserDefaults.standard.set("LEGACY-RACE", forKey: "raceCurrentRaceName")

        // Reading raceEntries should migrate
        let entries = RaceSettings.shared.raceEntries
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].url, "https://server/races/legacy")
        XCTAssertEqual(entries[0].name, "LEGACY-RACE")

        // Legacy keys should be removed after migration
        XCTAssertNil(UserDefaults.standard.string(forKey: "raceURL"))
        XCTAssertNil(UserDefaults.standard.string(forKey: "raceCurrentRaceName"))
    }

    func testMigration_noLegacyKey_returnsEmpty() {
        XCTAssertTrue(RaceSettings.shared.raceEntries.isEmpty)
    }
}
```

- [ ] **Step 2: Run tests — expect failure**

```bash
xcodebuild test \
  -project "Claude Usage.xcodeproj" \
  -scheme "Claude Usage" \
  -destination "platform=macOS,arch=arm64" \
  -only-testing "Claude UsageTests/RaceSettingsTests" \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO \
  2>&1 | grep -E "(error:|cannot find|FAILED)" | head -10
```

Expected: errors about `raceEntries`, `addRaceEntry`, etc.

- [ ] **Step 3: Update `Claude Usage/Shared/Storage/RaceSettings.swift`**

Replace the entire file:

```swift
// Claude Usage/Shared/Storage/RaceSettings.swift
import Foundation

/// Persists horse race configuration in UserDefaults.
final class RaceSettings {
    static let shared = RaceSettings()

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let raceEnabled       = "raceEnabled"
        static let participantName   = "raceParticipantName"
        static let pushInterval      = "racePushInterval"
        static let pollInterval      = "racePollInterval"
        static let participantID     = "raceParticipantID"
        static let serverBaseURL     = "raceServerBaseURL"
        static let raceEntries       = "raceEntries"
        // Legacy keys (pre-multi-race) — only used for migration
        static let legacyRaceURL     = "raceURL"
        static let legacyRaceName    = "raceCurrentRaceName"
    }

    // MARK: - Race Enabled

    var raceEnabled: Bool {
        get { defaults.bool(forKey: Keys.raceEnabled) }
        set { defaults.set(newValue, forKey: Keys.raceEnabled) }
    }

    // MARK: - Participant Name

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

    // MARK: - Server Base URL

    var serverBaseURL: String? {
        get { defaults.string(forKey: Keys.serverBaseURL).flatMap { $0.isEmpty ? nil : $0 } }
        set { defaults.set(newValue ?? "", forKey: Keys.serverBaseURL) }
    }

    // MARK: - Participant Identity

    var participantID: String {
        let stored = defaults.string(forKey: Keys.participantID) ?? ""
        if !stored.isEmpty { return stored }
        let newID = UUID().uuidString
        defaults.set(newID, forKey: Keys.participantID)
        return newID
    }

    // MARK: - Race Entries (replaces single raceURL/raceName)

    var raceEntries: [RaceEntry] {
        get {
            if let data = defaults.data(forKey: Keys.raceEntries),
               let entries = try? JSONDecoder().decode([RaceEntry].self, from: data) {
                return entries
            }
            // One-time migration from legacy single-race keys
            if let legacyURL = defaults.string(forKey: Keys.legacyRaceURL),
               !legacyURL.isEmpty {
                let entry = RaceEntry(
                    url: legacyURL,
                    name: defaults.string(forKey: Keys.legacyRaceName)
                )
                let migrated = [entry]
                if let encoded = try? JSONEncoder().encode(migrated) {
                    defaults.set(encoded, forKey: Keys.raceEntries)
                }
                defaults.removeObject(forKey: Keys.legacyRaceURL)
                defaults.removeObject(forKey: Keys.legacyRaceName)
                return migrated
            }
            return []
        }
        set {
            if let encoded = try? JSONEncoder().encode(newValue) {
                defaults.set(encoded, forKey: Keys.raceEntries)
            }
        }
    }

    func addRaceEntry(_ entry: RaceEntry) {
        var entries = raceEntries
        entries.append(entry)
        raceEntries = entries
    }

    func removeRaceEntry(id: UUID) {
        raceEntries = raceEntries.filter { $0.id != id }
    }

    func updateRaceEntryName(url: String, name: String) {
        var entries = raceEntries
        if let idx = entries.firstIndex(where: { $0.url == url }) {
            entries[idx].name = name
            raceEntries = entries
        }
    }
}
```

- [ ] **Step 4: Run tests — expect pass**

```bash
xcodebuild test \
  -project "Claude Usage.xcodeproj" \
  -scheme "Claude Usage" \
  -destination "platform=macOS,arch=arm64" \
  -only-testing "Claude UsageTests/RaceSettingsTests" \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO \
  2>&1 | grep -E "(Test Suite|PASSED|FAILED)" | tail -5
```

Expected: `Test Suite 'RaceSettingsTests' passed`

- [ ] **Step 5: Build to verify nothing else broke**

Run the build verification command. Expected: `BUILD SUCCEEDED`

- [ ] **Step 6: Commit**

```bash
git add "Claude Usage/Shared/Storage/RaceSettings.swift" \
        "Claude UsageTests/RaceSettingsTests.swift"
git commit -m "feat: Replace single raceURL with raceEntries list + migration"
```

---

## Task 3: RaceService — Multi-Race Push/Poll/Compile

**Files:**
- Modify: `Claude Usage/Shared/Services/RaceService.swift`
- Create: `Claude UsageTests/RaceServiceCompileTests.swift`

- [ ] **Step 1: Write the failing compile tests**

```swift
// Claude UsageTests/RaceServiceCompileTests.swift
import XCTest
@testable import Claude_Usage

final class RaceServiceCompileTests: XCTestCase {

    private func makeParticipant(name: String, usedCents: Int, limitCents: Int = 100000) -> RaceParticipant {
        RaceParticipant(
            name: name,
            costUsedCents: usedCents,
            costLimitCents: limitCents,
            updatedAt: Date()
        )
    }

    private func makeStandings(slug: String, participants: [RaceParticipant]) -> RaceStandings {
        RaceStandings(raceSlug: slug, name: slug, participants: participants)
    }

    func testCompile_emptyStandings_returnsEmpty() {
        let result = RaceService.compile(from: [:])
        XCTAssertTrue(result.isEmpty)
    }

    func testCompile_singleRace_returnsAllParticipants() {
        let standings = makeStandings(slug: "A", participants: [
            makeParticipant(name: "Alice", usedCents: 6150),
            makeParticipant(name: "Ben", usedCents: 4230),
        ])
        let result = RaceService.compile(from: ["url-a": standings])
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].name, "Alice") // highest first
    }

    func testCompile_multiRace_deduplicatesByName_keepsHighest() {
        let raceA = makeStandings(slug: "A", participants: [
            makeParticipant(name: "Alice", usedCents: 6150),
            makeParticipant(name: "Ben", usedCents: 2000),
        ])
        let raceB = makeStandings(slug: "B", participants: [
            makeParticipant(name: "Alice", usedCents: 3000), // lower than in A
            makeParticipant(name: "Carol", usedCents: 5000),
        ])
        let result = RaceService.compile(from: ["url-a": raceA, "url-b": raceB])
        XCTAssertEqual(result.count, 3) // Alice, Ben, Carol — no duplicates
        let alice = result.first { $0.name == "Alice" }!
        XCTAssertEqual(alice.costUsedCents, 6150) // kept the higher value from race A
    }

    func testCompile_sortedDescendingByPercent() {
        let standings = makeStandings(slug: "A", participants: [
            makeParticipant(name: "Carol", usedCents: 1800),
            makeParticipant(name: "Alice", usedCents: 6150),
            makeParticipant(name: "Ben", usedCents: 4230),
        ])
        let result = RaceService.compile(from: ["url-a": standings])
        XCTAssertEqual(result[0].name, "Alice")
        XCTAssertEqual(result[1].name, "Ben")
        XCTAssertEqual(result[2].name, "Carol")
    }

    func testCompile_sameName_sameValueInBothRaces_appearsOnce() {
        let raceA = makeStandings(slug: "A", participants: [
            makeParticipant(name: "Alice", usedCents: 5000),
        ])
        let raceB = makeStandings(slug: "B", participants: [
            makeParticipant(name: "Alice", usedCents: 5000),
        ])
        let result = RaceService.compile(from: ["url-a": raceA, "url-b": raceB])
        XCTAssertEqual(result.count, 1)
    }
}
```

- [ ] **Step 2: Run tests — expect failure**

```bash
xcodebuild test \
  -project "Claude Usage.xcodeproj" \
  -scheme "Claude Usage" \
  -destination "platform=macOS,arch=arm64" \
  -only-testing "Claude UsageTests/RaceServiceCompileTests" \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO \
  2>&1 | grep -E "(error:|cannot find|FAILED)" | head -5
```

Expected: `compile` not found.

- [ ] **Step 3: Replace `Claude Usage/Shared/Services/RaceService.swift` entirely**

```swift
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
                // Cache display name from server
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
    /// Sorted descending by percentUsed.
    static func compile(from allStandings: [String: RaceStandings]) -> [RaceParticipant] {
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
```

- [ ] **Step 4: Run compile tests — expect pass**

```bash
xcodebuild test \
  -project "Claude Usage.xcodeproj" \
  -scheme "Claude Usage" \
  -destination "platform=macOS,arch=arm64" \
  -only-testing "Claude UsageTests/RaceServiceCompileTests" \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO \
  2>&1 | grep -E "(Test Suite|PASSED|FAILED)" | tail -5
```

Expected: `Test Suite 'RaceServiceCompileTests' passed`

- [ ] **Step 5: Full build**

Run build verification. Expected: `BUILD SUCCEEDED`

- [ ] **Step 6: Commit**

```bash
git add "Claude Usage/Shared/Services/RaceService.swift" \
        "Claude UsageTests/RaceServiceCompileTests.swift"
git commit -m "feat: Multi-race push/poll, static compile() with deduplication"
```

---

## Task 4: HorseRaceSettingsView — Race List UI

**Files:**
- Modify: `Claude Usage/Views/Settings/App/HorseRaceSettingsView.swift`

Read the full file before editing. The changes are:

1. Remove `@State private var currentRaceURL` and `@State private var currentRaceName` and `@State private var urlCopied`
2. Add `@State private var raceEntries: [RaceEntry] = RaceSettings.shared.raceEntries`
3. Remove `currentRaceSection` computed var and remove `if currentRaceURL != nil { currentRaceSection }` from body
4. Add `racesSection` in its place (always shown)
5. Update `joinRace()` to use `addRaceEntry` instead of `raceURL`/`raceName`
6. Update `leaveRace()` to take a `RaceEntry` and call `removeRaceEntry`
7. Update `saveName()` to rename in ALL race entries
8. Remove `refreshCurrentRace()` helper, replace with `refreshEntries()`

- [ ] **Step 1: Replace `currentRaceSection` with `racesSection`**

Remove `currentRaceSection` and replace the `if currentRaceURL != nil { currentRaceSection }` line in `body` with `racesSection`.

Add this computed var:

```swift
private var racesSection: some View {
    SettingsSectionCard(
        title: "Races",
        subtitle: raceEntries.isEmpty ? "Join or create a race to get started." : nil
    ) {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(raceEntries) { entry in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name ?? URL(string: entry.url)?.lastPathComponent ?? entry.url)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.primary)
                            .lineLimit(1)

                        Text(entry.url)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer()

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(entry.url, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Copy URL")

                    Button {
                        leaveRace(entry: entry)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .help("Leave race")
                }
                .padding(.vertical, 2)
            }
        }
    }
}
```

- [ ] **Step 2: Update `joinRace()` to use `addRaceEntry`**

Replace the two lines that set `raceURL`/`raceName` in `joinRace()`:
```swift
// Remove:
RaceSettings.shared.raceURL = urlString
RaceSettings.shared.raceName = standings?.name

// Replace with:
let entry = RaceEntry(url: urlString, name: standings?.name)
RaceSettings.shared.addRaceEntry(entry)
```

And replace `refreshCurrentRace()` call with `refreshEntries()`.

- [ ] **Step 3: Update `leaveRace()` to take an entry**

Replace the existing `leaveRace()`:

```swift
private func leaveRace(entry: RaceEntry) {
    RaceSettings.shared.removeRaceEntry(id: entry.id)
    RaceService.shared.restart()
    refreshEntries()
}
```

- [ ] **Step 4: Add `refreshEntries()`, remove `refreshCurrentRace()`**

Remove `refreshCurrentRace()`. Add:

```swift
private func refreshEntries() {
    raceEntries = RaceSettings.shared.raceEntries
}
```

- [ ] **Step 5: Update `saveName()` to rename in all races**

Replace the block that reads `RaceSettings.shared.raceURL` with a loop over all entries:

```swift
// Remove the single-race guard and request block.
// Replace with:
let entries = RaceSettings.shared.raceEntries
guard !entries.isEmpty else {
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

Task {
    var anyConflict = false
    for entry in entries {
        guard let baseURL = URL(string: entry.url) else { continue }
        var request = URLRequest(url: baseURL.appendingPathComponent("participant/rename"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 10
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 409 {
                anyConflict = true
            }
        } catch { }
    }
    await MainActor.run {
        if anyConflict {
            nameError = "Name already taken"
            participantName = old
        } else {
            RaceSettings.shared.participantName = trimmed
            previousName = trimmed
            nameError = nil
        }
    }
}
```

- [ ] **Step 6: Build to verify**

Run build verification. Expected: `BUILD SUCCEEDED`

- [ ] **Step 7: Commit**

```bash
git add "Claude Usage/Views/Settings/App/HorseRaceSettingsView.swift"
git commit -m "feat: Replace single race section with joined races list"
```

---

## Task 5: RaceTabView — Use compiledStandings

**Files:**
- Modify: `Claude Usage/MenuBar/RaceTabView.swift`

Read the file before editing. Three targeted changes:

- [ ] **Step 1: Update not-configured check in `body`**

Find:
```swift
} else if !RaceSettings.shared.raceEnabled || RaceSettings.shared.raceURL == nil {
```

Replace with:
```swift
} else if !RaceSettings.shared.raceEnabled || RaceSettings.shared.raceEntries.isEmpty {
```

- [ ] **Step 2: Update participant source in `liveView`**

Find:
```swift
if let participants = raceService.standings?.participants, !participants.isEmpty {
```

Replace with:
```swift
if !raceService.compiledStandings.isEmpty {
    let participants = raceService.compiledStandings
```

Note: the closing `}` of the `if let` block needs adjusting — `participants` is now a `let` inside the `if` block. Check that all `participants` references below are still in scope and adjust bracing if needed.

- [ ] **Step 3: Update `raceSlugDisplay`**

Replace the entire `raceSlugDisplay` computed property:

```swift
private var raceSlugDisplay: String {
    let entries = RaceSettings.shared.raceEntries
    if entries.count == 1 {
        return entries[0].name
            ?? URL(string: entries[0].url)?.lastPathComponent
            ?? "RACE"
    } else if entries.count > 1 {
        return "\(entries.count) races"
    }
    return "RACE"
}
```

- [ ] **Step 4: Build to verify**

Run build verification. Expected: `BUILD SUCCEEDED`

- [ ] **Step 5: Run all tests**

Run the full test suite. Expected: all existing tests still pass plus the new ones.

- [ ] **Step 6: Commit**

```bash
git add "Claude Usage/MenuBar/RaceTabView.swift"
git commit -m "feat: RaceTabView uses compiledStandings, multi-race header"
```
