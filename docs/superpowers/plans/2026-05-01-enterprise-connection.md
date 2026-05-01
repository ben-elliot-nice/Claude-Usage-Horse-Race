# Enterprise Connection Type Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an "Enterprise Account" credential type that authenticates like claude.ai but parses `extra_usage` from the `/usage` endpoint as per-user monthly spend, displayed in the session bar as "Monthly Spend".

**Architecture:** New `ConnectionType` enum on `Profile` controls which fetch path `UsageRefreshCoordinator` uses. Enterprise fetch logic lives in a new `ClaudeAPIService+Enterprise.swift` extension (following the existing `+ConsoleAPI` pattern) and never touches `ClaudeAPIService.swift`. The Settings UI follows the `PersonalUsageView` wizard pattern exactly, saving `connectionType = .enterprise` alongside the session key.

**Tech Stack:** Swift/SwiftUI (macOS), XCTest, existing ClaudeAPIService auth infrastructure.

---

## Worktree

All work is in the repo at:
```
/Users/Ben.Elliot/repos/claude-usage-horse-race/
```

Branch: `develop`

## Build Verification

```bash
xcodebuild build \
  -project "/Users/Ben.Elliot/repos/claude-usage-horse-race/Claude Usage.xcodeproj" \
  -scheme "Claude Usage" \
  -destination "platform=macOS,arch=arm64" \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO \
  2>&1 | grep -E "^(error:|BUILD)" | tail -10
```

Expected: `BUILD SUCCEEDED`

## Run Tests

```bash
xcodebuild test \
  -project "/Users/Ben.Elliot/repos/claude-usage-horse-race/Claude Usage.xcodeproj" \
  -scheme "Claude Usage" \
  -destination "platform=macOS,arch=arm64" \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO \
  2>&1 | grep -E "(Test Suite|PASSED|FAILED|error:)" | tail -15
```

## Note on Xcode File Discovery

The project uses `PBXFileSystemSynchronizedRootGroup` — new Swift files placed in the correct directory are auto-discovered. No `.pbxproj` edits needed.

---

## File Map

| File | Action | Responsibility |
|------|--------|---------------|
| `Claude Usage/Shared/Models/ConnectionType.swift` | Create | `ConnectionType` enum — `.claudeAI`, `.cliOAuth`, `.console`, `.enterprise` |
| `Claude Usage/Shared/Models/Profile.swift` | Modify | Add `var connectionType: ConnectionType = .claudeAI` |
| `Claude Usage/Shared/Services/ClaudeAPIService+Enterprise.swift` | Create | `fetchEnterpriseUsageData()` + `parseEnterpriseUsageResponse()` |
| `Claude Usage/MenuBar/UsageRefreshCoordinator.swift` | Modify | Add enterprise branch at fetch call site |
| `Claude Usage/Views/Settings/Credentials/EnterpriseCredentialsView.swift` | Create | Settings UI for enterprise session key (wizard reuse) |
| `Claude Usage/Views/SettingsView.swift` | Modify | Add `case enterprise` to `SettingsSection` |
| `Claude Usage/MenuBar/PopoverContentView.swift` | Modify | Rename session bar label to "Monthly Spend" when enterprise |
| `Claude Usage/MenuBar/RaceTabView.swift` | Modify | Add enterprise prerequisite gate before race content |
| `Claude UsageTests/ConnectionTypeTests.swift` | Create | Codable round-trip, default value tests |
| `Claude UsageTests/EnterpriseParseTests.swift` | Create | `parseEnterpriseUsageResponse` unit tests |

---

## Task 1: ConnectionType Enum

**Files:**
- Create: `Claude Usage/Shared/Models/ConnectionType.swift`
- Create: `Claude UsageTests/ConnectionTypeTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// Claude UsageTests/ConnectionTypeTests.swift
import XCTest
@testable import Claude_Usage

final class ConnectionTypeTests: XCTestCase {

    func testDefaultIsClaudeAI() {
        // Profile's default should be .claudeAI
        // We test by creating a ConnectionType from a missing key scenario
        let decoded = try? JSONDecoder().decode(ConnectionType.self,
                                                from: Data("\"claudeAI\"".utf8))
        XCTAssertEqual(decoded, .claudeAI)
    }

    func testEnterpriseRoundTrip() throws {
        let encoded = try JSONEncoder().encode(ConnectionType.enterprise)
        let decoded = try JSONDecoder().decode(ConnectionType.self, from: encoded)
        XCTAssertEqual(decoded, .enterprise)
    }

    func testAllCasesRoundTrip() throws {
        for connectionType in [ConnectionType.claudeAI, .cliOAuth, .console, .enterprise] {
            let encoded = try JSONEncoder().encode(connectionType)
            let decoded = try JSONDecoder().decode(ConnectionType.self, from: encoded)
            XCTAssertEqual(decoded, connectionType)
        }
    }

    func testUnknownRawValueDecodesAsClaudeAI() throws {
        // Fallback for future upstream cases we don't know about
        // Codable will throw on unknown enum case — this documents that behaviour
        XCTAssertThrowsError(
            try JSONDecoder().decode(ConnectionType.self,
                                     from: Data("\"unknownFutureCase\"".utf8))
        )
    }
}
```

- [ ] **Step 2: Run tests — expect failure**

```bash
xcodebuild test \
  -project "/Users/Ben.Elliot/repos/claude-usage-horse-race/Claude Usage.xcodeproj" \
  -scheme "Claude Usage" \
  -destination "platform=macOS,arch=arm64" \
  -only-testing "Claude UsageTests/ConnectionTypeTests" \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO \
  2>&1 | grep -E "(error:|cannot find)" | head -5
```

Expected: `ConnectionType` not found.

- [ ] **Step 3: Write the enum**

```swift
// Claude Usage/Shared/Models/ConnectionType.swift
import Foundation

/// Determines how a profile authenticates and fetches usage data.
/// Stored as a String raw value for Codable compatibility.
enum ConnectionType: String, Codable {
    /// Standard claude.ai session key — parses five_hour/seven_day utilisation
    case claudeAI
    /// CLI OAuth token — parses usage from Messages API rate limit headers
    case cliOAuth
    /// Anthropic Console API session key — provides billing/credit data
    case console
    /// Enterprise claude.ai session key — parses extra_usage as monthly spend
    case enterprise
}
```

- [ ] **Step 4: Run tests — expect pass**

```bash
xcodebuild test \
  -project "/Users/Ben.Elliot/repos/claude-usage-horse-race/Claude Usage.xcodeproj" \
  -scheme "Claude Usage" \
  -destination "platform=macOS,arch=arm64" \
  -only-testing "Claude UsageTests/ConnectionTypeTests" \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO \
  2>&1 | grep -E "(Test Suite|PASSED|FAILED)" | tail -5
```

Expected: `Test Suite 'ConnectionTypeTests' passed`

- [ ] **Step 5: Commit**

```bash
git add "Claude Usage/Shared/Models/ConnectionType.swift" \
        "Claude UsageTests/ConnectionTypeTests.swift"
git commit -m "feat: Add ConnectionType enum"
```

---

## Task 2: Profile.connectionType

**Files:**
- Modify: `Claude Usage/Shared/Models/Profile.swift`

- [ ] **Step 1: Add the field**

In `Profile.swift`, find the `// MARK: - Metadata` section near the end of the struct properties. Add `connectionType` alongside the other behaviour settings in `// MARK: - Behavior Settings (Per-Profile)`:

```swift
// MARK: - Behavior Settings (Per-Profile)
var refreshInterval: TimeInterval
var autoStartSessionEnabled: Bool
var checkOverageLimitEnabled: Bool
var connectionType: ConnectionType       // ← add this line
```

- [ ] **Step 2: Add default to the `init`**

In `Profile.init(...)`, add the parameter with a default value. Find the parameter list and add after `checkOverageLimitEnabled`:

```swift
checkOverageLimitEnabled: Bool = true,
connectionType: ConnectionType = .claudeAI,   // ← add this
notificationSettings: NotificationSettings = NotificationSettings(),
```

And in the body of `init`:

```swift
self.checkOverageLimitEnabled = checkOverageLimitEnabled
self.connectionType = connectionType           // ← add this
self.notificationSettings = notificationSettings
```

- [ ] **Step 3: Build to verify — no existing callers broken**

```bash
xcodebuild build \
  -project "/Users/Ben.Elliot/repos/claude-usage-horse-race/Claude Usage.xcodeproj" \
  -scheme "Claude Usage" \
  -destination "platform=macOS,arch=arm64" \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO \
  2>&1 | grep -E "^(error:|BUILD)" | tail -5
```

Expected: `BUILD SUCCEEDED` — the default parameter means all existing `Profile(...)` call sites continue to compile.

- [ ] **Step 4: Commit**

```bash
git add "Claude Usage/Shared/Models/Profile.swift"
git commit -m "feat: Add connectionType field to Profile (default .claudeAI)"
```

---

## Task 3: Enterprise Fetch + Parse

**Files:**
- Create: `Claude Usage/Shared/Services/ClaudeAPIService+Enterprise.swift`
- Create: `Claude UsageTests/EnterpriseParseTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// Claude UsageTests/EnterpriseParseTests.swift
import XCTest
@testable import Claude_Usage

final class EnterpriseParseTests: XCTestCase {

    // Helper to call the private parse method via a test-accessible wrapper
    // We test via the public interface by encoding a known JSON response
    private let service = ClaudeAPIService()

    func makeResponseData(extraUsage: [String: Any]?) -> Data {
        var json: [String: Any] = [
            "five_hour": NSNull(),
            "seven_day": NSNull(),
        ]
        if let eu = extraUsage {
            json["extra_usage"] = eu
        }
        return try! JSONSerialization.data(withJSONObject: json)
    }

    func testParseExtraUsage_normal() throws {
        let data = makeResponseData(extraUsage: [
            "is_enabled": true,
            "monthly_limit": 100000,
            "used_credits": 660.0,
            "utilization": 0.0066,
            "currency": "USD"
        ])
        let usage = try service.parseEnterpriseResponse(data)

        // utilization is 0.0066 → multiply by 100 → 0.66%
        XCTAssertEqual(usage.sessionPercentage, 0.66, accuracy: 0.001)
        XCTAssertEqual(usage.costUsed, 660.0)
        XCTAssertEqual(usage.costLimit, 100000.0)
        XCTAssertEqual(usage.costCurrency, "USD")
    }

    func testParseExtraUsage_zeroUsed() throws {
        let data = makeResponseData(extraUsage: [
            "is_enabled": true,
            "monthly_limit": 100000,
            "used_credits": 0.0,
            "utilization": 0.0,
            "currency": "USD"
        ])
        let usage = try service.parseEnterpriseResponse(data)
        XCTAssertEqual(usage.sessionPercentage, 0.0)
        XCTAssertEqual(usage.costUsed, 0.0)
    }

    func testParseExtraUsage_weeklyFieldsAreZero() throws {
        let data = makeResponseData(extraUsage: [
            "is_enabled": true,
            "monthly_limit": 100000,
            "used_credits": 500.0,
            "utilization": 0.005,
            "currency": "USD"
        ])
        let usage = try service.parseEnterpriseResponse(data)
        XCTAssertEqual(usage.weeklyTokensUsed, 0)
        XCTAssertEqual(usage.weeklyPercentage, 0.0)
        XCTAssertEqual(usage.opusWeeklyTokensUsed, 0)
        XCTAssertEqual(usage.sonnetWeeklyTokensUsed, 0)
    }

    func testParseExtraUsage_missingExtraUsage_throws() {
        let data = makeResponseData(extraUsage: nil)
        XCTAssertThrowsError(try service.parseEnterpriseResponse(data)) { error in
            guard let appError = error as? AppError else {
                XCTFail("Expected AppError")
                return
            }
            XCTAssertEqual(appError.code, .apiParsingFailed)
        }
    }

    func testParseExtraUsage_disabledExtraUsage_throws() {
        let data = makeResponseData(extraUsage: [
            "is_enabled": false,
            "monthly_limit": 100000,
            "used_credits": 0.0,
            "utilization": 0.0,
            "currency": "USD"
        ])
        XCTAssertThrowsError(try service.parseEnterpriseResponse(data)) { error in
            guard let appError = error as? AppError else {
                XCTFail("Expected AppError")
                return
            }
            XCTAssertEqual(appError.code, .apiParsingFailed)
        }
    }

    func testResetTimeIsEndOfCurrentMonth() throws {
        let data = makeResponseData(extraUsage: [
            "is_enabled": true,
            "monthly_limit": 100000,
            "used_credits": 100.0,
            "utilization": 0.001,
            "currency": "USD"
        ])
        let usage = try service.parseEnterpriseResponse(data)

        // Reset time should be in the future (end of current or next month)
        XCTAssertGreaterThan(usage.sessionResetTime, Date())

        // Should be within 32 days
        let thirtyTwoDays: TimeInterval = 32 * 24 * 60 * 60
        XCTAssertLessThan(usage.sessionResetTime.timeIntervalSinceNow, thirtyTwoDays)
    }
}
```

- [ ] **Step 2: Run tests — expect failure**

```bash
xcodebuild test \
  -project "/Users/Ben.Elliot/repos/claude-usage-horse-race/Claude Usage.xcodeproj" \
  -scheme "Claude Usage" \
  -destination "platform=macOS,arch=arm64" \
  -only-testing "Claude UsageTests/EnterpriseParseTests" \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO \
  2>&1 | grep -E "(error:|cannot find)" | head -5
```

Expected: `parseEnterpriseResponse` not found.

- [ ] **Step 3: Write the extension**

```swift
// Claude Usage/Shared/Services/ClaudeAPIService+Enterprise.swift
import Foundation

// MARK: - Enterprise Account Support

extension ClaudeAPIService {

    /// Fetches usage data for an enterprise claude.ai account.
    /// Uses the same /usage endpoint as the standard flow but reads
    /// the `extra_usage` block instead of `five_hour`/`seven_day`.
    func fetchEnterpriseUsageData(sessionKey: String, organizationId: String) async throws -> ClaudeUsage {
        let data = try await performRequest(
            endpoint: "/organizations/\(organizationId)/usage",
            sessionKey: sessionKey
        )
        return try parseEnterpriseResponse(data)
    }

    /// Parses the `extra_usage` block from the /usage response.
    /// - Throws: `AppError(.apiParsingFailed)` if `extra_usage` is absent or disabled.
    func parseEnterpriseResponse(_ data: Data) throws -> ClaudeUsage {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let extraUsage = json["extra_usage"] as? [String: Any] else {
            throw AppError(
                code: .apiParsingFailed,
                message: "No extra_usage data available",
                technicalDetails: "This account may not have Enterprise extra usage enabled",
                isRecoverable: false,
                recoverySuggestion: "Ensure your account has an Enterprise extra usage allocation, or switch to a different connection type"
            )
        }

        let isEnabled = extraUsage["is_enabled"] as? Bool ?? false
        guard isEnabled else {
            throw AppError(
                code: .apiParsingFailed,
                message: "Enterprise extra usage is not enabled for this account",
                isRecoverable: false,
                recoverySuggestion: "Contact your administrator to enable extra usage for your account"
            )
        }

        // utilization is 0.0–1.0 from the API; convert to 0–100 percentage
        let utilization = (extraUsage["utilization"] as? Double ?? 0.0) * 100.0
        let usedCredits = extraUsage["used_credits"] as? Double ?? 0.0
        let monthlyLimit = extraUsage["monthly_limit"] as? Double ?? 0.0
        let currency = extraUsage["currency"] as? String ?? "USD"

        // Reset time = last second of the current calendar month
        let resetTime = endOfCurrentMonth()

        return ClaudeUsage(
            sessionTokensUsed: 0,
            sessionLimit: 0,
            sessionPercentage: utilization,
            sessionResetTime: resetTime,
            weeklyTokensUsed: 0,
            weeklyLimit: 0,
            weeklyPercentage: 0.0,
            weeklyResetTime: Date().nextMonday1259pm(),
            opusWeeklyTokensUsed: 0,
            opusWeeklyPercentage: 0.0,
            sonnetWeeklyTokensUsed: 0,
            sonnetWeeklyPercentage: 0.0,
            sonnetWeeklyResetTime: nil,
            costUsed: usedCredits,
            costLimit: monthlyLimit,
            costCurrency: currency,
            overageBalance: nil,
            overageBalanceCurrency: nil,
            lastUpdated: Date(),
            userTimezone: .current
        )
    }

    // MARK: - Private Helpers

    private func endOfCurrentMonth() -> Date {
        var calendar = Calendar.current
        calendar.timeZone = TimeZone.current
        let now = Date()
        // Start of next month, minus 1 second = last second of current month
        var components = calendar.dateComponents([.year, .month], from: now)
        components.month! += 1
        let startOfNextMonth = calendar.date(from: components) ?? now.addingTimeInterval(30 * 24 * 3600)
        return startOfNextMonth.addingTimeInterval(-1)
    }
}
```

- [ ] **Step 4: Run tests — expect pass**

```bash
xcodebuild test \
  -project "/Users/Ben.Elliot/repos/claude-usage-horse-race/Claude Usage.xcodeproj" \
  -scheme "Claude Usage" \
  -destination "platform=macOS,arch=arm64" \
  -only-testing "Claude UsageTests/EnterpriseParseTests" \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO \
  2>&1 | grep -E "(Test Suite|PASSED|FAILED)" | tail -5
```

Expected: `Test Suite 'EnterpriseParseTests' passed`

- [ ] **Step 5: Commit**

```bash
git add "Claude Usage/Shared/Services/ClaudeAPIService+Enterprise.swift" \
        "Claude UsageTests/EnterpriseParseTests.swift"
git commit -m "feat: Add enterprise fetch and parse (extra_usage block)"
```

---

## Task 4: UsageRefreshCoordinator Enterprise Branch

**Files:**
- Modify: `Claude Usage/MenuBar/UsageRefreshCoordinator.swift`

The coordinator currently calls `apiService.fetchUsageData()` on line 58. We add an enterprise branch before this call.

- [ ] **Step 1: Add a private helper and update `refreshUsage()`**

Add this private helper method to `UsageRefreshCoordinator` (inside the class, before `refreshUsage()`):

```swift
/// Fetches usage data using the appropriate strategy for the active profile's connection type.
private func fetchUsageForActiveProfile() async throws -> ClaudeUsage {
    let profile = await MainActor.run { ProfileManager.shared.activeProfile }

    if profile?.connectionType == .enterprise,
       let claudeService = apiService as? ClaudeAPIService,
       let sessionKey = profile?.claudeSessionKey,
       let orgId = profile?.organizationId {
        return try await claudeService.fetchEnterpriseUsageData(sessionKey: sessionKey, organizationId: orgId)
    }

    return try await apiService.fetchUsageData()
}
```

Then in `refreshUsage()`, replace the single line:

```swift
// Before:
async let usageResult = apiService.fetchUsageData()

// After:
async let usageResult = fetchUsageForActiveProfile()
```

No other changes to `refreshUsage()` — `try await usageResult` in the `do` block remains unchanged.

- [ ] **Step 2: Build to verify**

```bash
xcodebuild build \
  -project "/Users/Ben.Elliot/repos/claude-usage-horse-race/Claude Usage.xcodeproj" \
  -scheme "Claude Usage" \
  -destination "platform=macOS,arch=arm64" \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO \
  2>&1 | grep -E "^(error:|BUILD)" | tail -10
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add "Claude Usage/MenuBar/UsageRefreshCoordinator.swift"
git commit -m "feat: Add enterprise fetch branch in UsageRefreshCoordinator"
```

---

## Task 5: Enterprise Credentials View

**Files:**
- Create: `Claude Usage/Views/Settings/Credentials/EnterpriseCredentialsView.swift`

Follows the `PersonalUsageView` wizard pattern. Reuses `EnterKeyStep` and `SelectOrgStep` from `PersonalUsageView.swift`. The key difference is the `ConfirmStep` equivalent saves `connectionType = .enterprise` on the profile.

- [ ] **Step 1: Write the view**

```swift
// Claude Usage/Views/Settings/Credentials/EnterpriseCredentialsView.swift
import SwiftUI

/// Enterprise Account credential setup.
/// Uses the same session key + org ID auth as PersonalUsageView, but sets
/// connectionType = .enterprise so usage is read from extra_usage (monthly spend).
struct EnterpriseCredentialsView: View {
    @StateObject private var profileManager = ProfileManager.shared
    @State private var wizardState = WizardState()
    @State private var isConnected = false
    @State private var maskedKey = ""
    private let apiService = ClaudeAPIService()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.section) {
                SettingsPageHeader(
                    title: "Enterprise Account",
                    subtitle: "For NiCE/enterprise claude.ai accounts. Shows your personal monthly spend against your allocated cap."
                )

                // Connection status card
                HStack(spacing: DesignTokens.Spacing.medium) {
                    Circle()
                        .fill(isConnected ? Color.green : Color.secondary.opacity(0.4))
                        .frame(width: DesignTokens.StatusDot.standard, height: DesignTokens.StatusDot.standard)

                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.extraSmall) {
                        Text(isConnected ? "Connected" : "Not connected")
                            .font(DesignTokens.Typography.bodyMedium)
                        if isConnected {
                            Text(maskedKey)
                                .font(DesignTokens.Typography.captionMono)
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                    if isConnected {
                        Button(action: removeCredentials) {
                            HStack(spacing: DesignTokens.Spacing.extraSmall) {
                                Image(systemName: "trash")
                                    .font(.system(size: DesignTokens.Icons.small))
                                Text("Remove")
                                    .font(DesignTokens.Typography.body)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .foregroundColor(.red)
                    }
                }
                .padding(DesignTokens.Spacing.medium)
                .background(DesignTokens.Colors.cardBackground)
                .cornerRadius(DesignTokens.Radius.card)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.card)
                        .strokeBorder(DesignTokens.Colors.cardBorder, lineWidth: 1)
                )

                // Wizard card
                VStack(alignment: .leading, spacing: 0) {
                    // Step indicator
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
                        Text("Configuration")
                            .font(DesignTokens.Typography.sectionTitle)
                            .foregroundColor(.secondary)

                        HStack(spacing: DesignTokens.Spacing.small) {
                            ForEach(1...3, id: \.self) { step in
                                let stepEnum = WizardStep(rawValue: step)!
                                let isCurrent = wizardState.currentStep == stepEnum
                                let isCompleted = wizardState.currentStep > stepEnum

                                HStack(spacing: DesignTokens.Spacing.extraSmall) {
                                    ZStack {
                                        Circle()
                                            .fill(isCompleted ? Color.green : (isCurrent ? Color.accentColor : Color.secondary.opacity(0.2)))
                                            .frame(width: 20, height: 20)
                                        if isCompleted {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 10, weight: .semibold))
                                                .foregroundColor(.white)
                                        } else {
                                            Text("\(step)")
                                                .font(.system(size: 11, weight: .medium))
                                                .foregroundColor(isCurrent ? .white : .secondary)
                                        }
                                    }
                                    if isCurrent {
                                        Text(stepTitle(for: step))
                                            .font(DesignTokens.Typography.body)
                                            .fontWeight(.medium)
                                    }
                                }
                                if step < 3 {
                                    Rectangle()
                                        .fill(isCompleted ? Color.green.opacity(0.3) : Color.secondary.opacity(0.2))
                                        .frame(height: 1)
                                }
                            }
                        }
                    }
                    .padding(DesignTokens.Spacing.cardPadding)
                    .padding(.bottom, DesignTokens.Spacing.extraSmall)

                    Divider()

                    Group {
                        switch wizardState.currentStep {
                        case .enterKey:
                            EnterKeyStep(wizardState: $wizardState, apiService: apiService)
                        case .selectOrg:
                            SelectOrgStep(wizardState: $wizardState)
                        case .confirm:
                            EnterpriseConfirmStep(
                                wizardState: $wizardState,
                                onSave: { loadStatus() }
                            )
                        }
                    }
                    .padding(DesignTokens.Spacing.cardPadding)
                    .animation(.easeInOut(duration: 0.25), value: wizardState.currentStep)
                }
                .background(DesignTokens.Colors.cardBackground)
                .cornerRadius(DesignTokens.Radius.card)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.card)
                        .strokeBorder(DesignTokens.Colors.cardBorder, lineWidth: 1)
                )
            }
            .padding()
        }
        .onAppear { loadStatus() }
        .onChange(of: profileManager.activeProfile?.id) { _, _ in
            loadStatus()
            wizardState = WizardState()
        }
    }

    private func stepTitle(for step: Int) -> String {
        switch step {
        case 1: return "setup.step.enter_session_key".localized
        case 2: return "wizard.select_organization".localized
        case 3: return "Confirm & Save"
        default: return ""
        }
    }

    private func loadStatus() {
        guard let profile = profileManager.activeProfile else {
            isConnected = false
            return
        }
        isConnected = profile.connectionType == .enterprise && profile.claudeSessionKey != nil
        if let key = profile.claudeSessionKey, isConnected {
            let prefix = String(key.prefix(12))
            let suffix = String(key.suffix(4))
            maskedKey = "\(prefix)•••••\(suffix)"
        }
    }

    private func removeCredentials() {
        guard let profileId = profileManager.activeProfile?.id else { return }
        do {
            try profileManager.removeClaudeAICredentials(for: profileId)
            // Reset connectionType back to .claudeAI
            if var profile = profileManager.activeProfile {
                profile.connectionType = .claudeAI
                profileManager.updateProfile(profile)
            }
            loadStatus()
            wizardState = WizardState()
        } catch {
            let appError = AppError.wrap(error)
            ErrorPresenter.shared.showAlert(for: appError)
        }
    }
}

// MARK: - Enterprise Confirm Step

/// Like PersonalUsageView's ConfirmStep but saves connectionType = .enterprise
struct EnterpriseConfirmStep: View {
    @Binding var wizardState: WizardState
    let onSave: () -> Void
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("wizard.review_config".localized)
                    .font(.system(size: 13, weight: .medium))
                Text("wizard.confirm_settings".localized)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            // Summary
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "key")
                        .font(.system(size: 14))
                        .foregroundColor(.accentColor)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("wizard.session_key".localized)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                        Text(maskKey(wizardState.sessionKey))
                            .font(.system(size: 12, design: .monospaced))
                    }
                }

                if let org = wizardState.testedOrganizations.first(where: { $0.uuid == wizardState.selectedOrgId }) {
                    Divider()
                    HStack(spacing: 10) {
                        Image(systemName: "building.2")
                            .font(.system(size: 14))
                            .foregroundColor(.accentColor)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("wizard.organization".localized)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.secondary)
                            Text(org.name)
                                .font(.system(size: 12, weight: .medium))
                            Text(org.uuid)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Divider()
                HStack(spacing: 8) {
                    Image(systemName: "building.2.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.accentColor)
                    Text("Connection type: Enterprise (monthly spend)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            .padding(12)
            .background(DesignTokens.Colors.cardBackground)
            .cornerRadius(6)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(DesignTokens.Colors.cardBorder, lineWidth: 1))

            HStack(spacing: 10) {
                Button(action: {
                    withAnimation { wizardState.currentStep = .selectOrg }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left").font(.system(size: 11))
                        Text("common.back".localized).font(.system(size: 12))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(isSaving)

                Spacer()

                Button(action: saveConfiguration) {
                    HStack(spacing: 6) {
                        if isSaving {
                            ProgressView().scaleEffect(0.8).frame(width: 12, height: 12)
                        } else {
                            Image(systemName: "checkmark.circle").font(.system(size: 12))
                        }
                        Text(isSaving ? "wizard.saving".localized : "wizard.save_configuration".localized)
                            .font(.system(size: 12))
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(isSaving)
            }
        }
    }

    private func saveConfiguration() {
        guard let profileId = ProfileManager.shared.activeProfile?.id else { return }
        isSaving = true

        Task {
            do {
                var creds = try ProfileStore.shared.loadProfileCredentials(profileId)
                creds.claudeSessionKey = wizardState.sessionKey
                creds.organizationId = wizardState.selectedOrgId
                try ProfileStore.shared.saveProfileCredentials(profileId, credentials: creds)

                if var profile = ProfileManager.shared.activeProfile {
                    profile.claudeSessionKey = wizardState.sessionKey
                    profile.organizationId = wizardState.selectedOrgId
                    profile.connectionType = .enterprise          // ← the key difference
                    ProfileManager.shared.updateProfile(profile)
                }

                try? StatuslineService.shared.updateScriptsIfInstalled()

                await MainActor.run {
                    NotificationCenter.default.post(name: .credentialsChanged, object: nil)
                    onSave()
                    withAnimation { wizardState = WizardState() }
                    isSaving = false
                }
            } catch {
                let appError = AppError.wrap(error)
                await MainActor.run {
                    wizardState.validationState = .error(appError.message)
                    isSaving = false
                }
            }
        }
    }

    private func maskKey(_ key: String) -> String {
        guard key.count > 20 else { return "•••••••••" }
        return "\(key.prefix(12))•••••\(key.suffix(4))"
    }
}
```

- [ ] **Step 2: Build to verify**

```bash
xcodebuild build \
  -project "/Users/Ben.Elliot/repos/claude-usage-horse-race/Claude Usage.xcodeproj" \
  -scheme "Claude Usage" \
  -destination "platform=macOS,arch=arm64" \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO \
  2>&1 | grep -E "^(error:|BUILD)" | tail -10
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add "Claude Usage/Views/Settings/Credentials/EnterpriseCredentialsView.swift"
git commit -m "feat: Add EnterpriseCredentialsView (wizard reuse, sets connectionType)"
```

---

## Task 6: SettingsView Enterprise Section

**Files:**
- Modify: `Claude Usage/Views/SettingsView.swift`

- [ ] **Step 1: Add `case enterprise` to the enum**

Find `enum SettingsSection: String, CaseIterable`. The credential cases are at the top (`.claudeAI`, `.apiConsole`, `.cliAccount`). Add `.enterprise` alongside them:

```swift
enum SettingsSection: String, CaseIterable {
    // Credentials (not shown in sidebar)
    case claudeAI
    case apiConsole
    case cliAccount
    case enterprise   // ← add this
```

- [ ] **Step 2: Add title**

In `var title: String`, add:
```swift
case .enterprise: return "Enterprise Account"
```

- [ ] **Step 3: Add icon**

In `var icon: String`, add:
```swift
case .enterprise: return "building.2.fill"
```

- [ ] **Step 4: Add description (if the property exists)**

In `var description: String`, add:
```swift
case .enterprise: return "NiCE Enterprise monthly spend"
```

- [ ] **Step 5: Add content routing**

Find the `switch selectedSection` in the detail view body. Add:
```swift
case .enterprise:
    EnterpriseCredentialsView()
```

- [ ] **Step 6: Add to sidebar**

Find where `.cliAccount` appears in the sidebar item list (look for `sidebarItem(section: .cliAccount)` or equivalent). Add `.enterprise` in the same credentials group:
```swift
sidebarItem(section: .enterprise)
```

- [ ] **Step 7: Build to verify**

```bash
xcodebuild build \
  -project "/Users/Ben.Elliot/repos/claude-usage-horse-race/Claude Usage.xcodeproj" \
  -scheme "Claude Usage" \
  -destination "platform=macOS,arch=arm64" \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO \
  2>&1 | grep -E "^(error:|BUILD)" | tail -10
```

- [ ] **Step 8: Commit**

```bash
git add "Claude Usage/Views/SettingsView.swift"
git commit -m "feat: Add Enterprise Account section to Settings sidebar"
```

---

## Task 7: Session Bar Label — "Monthly Spend"

**Files:**
- Modify: `Claude Usage/MenuBar/PopoverContentView.swift`

In `SmartUsageDashboard`, the primary `UsageRow` for session usage is:

```swift
UsageRow(
    title: "menubar.session_usage".localized,
    subtitle: "menubar.5_hour_window".localized,
    usedPercentage: usage.effectiveSessionPercentage,
    ...
)
```

- [ ] **Step 1: Read the SmartUsageDashboard section**

Find the `SmartUsageDashboard` struct in `PopoverContentView.swift` (around line 544). Locate the `UsageRow` for session usage — it's the first row in the `body`.

- [ ] **Step 2: Add connection-type-aware labels**

Add a computed property to `SmartUsageDashboard`:

```swift
private var isEnterprise: Bool {
    if profileManager.displayMode == .multi {
        return false  // multi-profile mode uses active profile's connection type
    }
    return profileManager.activeProfile?.connectionType == .enterprise
}
```

Replace the session `UsageRow` call:

```swift
// Before:
UsageRow(
    title: "menubar.session_usage".localized,
    subtitle: "menubar.5_hour_window".localized,
    usedPercentage: usage.effectiveSessionPercentage,
    showRemaining: showRemainingPercentage,
    resetTime: usage.sessionResetTime,
    periodDuration: Constants.sessionWindow,
    showTimeMarker: showTimeMarker,
    showPaceMarker: showPaceMarker,
    usePaceColoring: usePaceColoring,
    timeDisplay: timeDisplay,
    isPeakHighlighted: isPeakHours
)

// After:
UsageRow(
    title: isEnterprise ? "Monthly Spend" : "menubar.session_usage".localized,
    subtitle: isEnterprise ? nil : "menubar.5_hour_window".localized,
    usedPercentage: usage.effectiveSessionPercentage,
    showRemaining: showRemainingPercentage,
    resetTime: usage.sessionResetTime,
    periodDuration: isEnterprise ? nil : Constants.sessionWindow,
    showTimeMarker: isEnterprise ? false : showTimeMarker,
    showPaceMarker: isEnterprise ? false : showPaceMarker,
    usePaceColoring: isEnterprise ? false : usePaceColoring,
    timeDisplay: timeDisplay,
    isPeakHighlighted: isPeakHours
)
```

Also hide the weekly rows when enterprise (they're zero):

```swift
// Before the "All Models (Weekly)" UsageRow, add:
if !isEnterprise {
    UsageRow(
        title: "menubar.all_models".localized,
        // ... existing weekly row
    )
    // ... opus, sonnet rows
}
```

- [ ] **Step 3: Build to verify**

```bash
xcodebuild build \
  -project "/Users/Ben.Elliot/repos/claude-usage-horse-race/Claude Usage.xcodeproj" \
  -scheme "Claude Usage" \
  -destination "platform=macOS,arch=arm64" \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO \
  2>&1 | grep -E "^(error:|BUILD)" | tail -10
```

- [ ] **Step 4: Commit**

```bash
git add "Claude Usage/MenuBar/PopoverContentView.swift"
git commit -m "feat: Show Monthly Spend label and hide weekly rows for enterprise accounts"
```

---

## Task 8: Race Tab Enterprise Gate

**Files:**
- Modify: `Claude Usage/MenuBar/RaceTabView.swift`

- [ ] **Step 1: Add the prerequisite check**

In `RaceTabView.body`, the current check is:

```swift
if !RaceSettings.shared.raceEnabled || RaceSettings.shared.raceURL == nil {
    notConfiguredView
} else if let error = raceService.lastError, raceService.standings == nil {
    errorView(message: error)
} else {
    liveView
}
```

Add the enterprise prerequisite as the outermost check:

```swift
if ProfileManager.shared.activeProfile?.connectionType != .enterprise {
    enterpriseRequiredView
} else if !RaceSettings.shared.raceEnabled || RaceSettings.shared.raceURL == nil {
    notConfiguredView
} else if let error = raceService.lastError, raceService.standings == nil {
    errorView(message: error)
} else {
    liveView
}
```

- [ ] **Step 2: Add `enterpriseRequiredView` property**

Add alongside the existing `notConfiguredView` computed property:

```swift
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
```

- [ ] **Step 3: Build and run all tests**

```bash
xcodebuild build \
  -project "/Users/Ben.Elliot/repos/claude-usage-horse-race/Claude Usage.xcodeproj" \
  -scheme "Claude Usage" \
  -destination "platform=macOS,arch=arm64" \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO \
  2>&1 | grep -E "^(error:|BUILD)" | tail -5

xcodebuild test \
  -project "/Users/Ben.Elliot/repos/claude-usage-horse-race/Claude Usage.xcodeproj" \
  -scheme "Claude Usage" \
  -destination "platform=macOS,arch=arm64" \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO \
  2>&1 | grep -E "(Test Suite|PASSED|FAILED)" | tail -10
```

Expected: `BUILD SUCCEEDED`, all test suites pass.

- [ ] **Step 4: Commit**

```bash
git add "Claude Usage/MenuBar/RaceTabView.swift"
git commit -m "feat: Gate race tab behind Enterprise Account prerequisite"
```
