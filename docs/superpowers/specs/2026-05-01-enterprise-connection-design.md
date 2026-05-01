# Enterprise Connection Type — Design Spec
_2026-05-01_

## Context

The Claude Usage app is a fork of an upstream project. NiCE runs Claude on an enterprise contract where per-user rate limit data (`five_hour`, `seven_day`) is null, but a `extra_usage` block in the `/usage` response provides per-user monthly spend against a personal dollar cap (e.g. $1,000/month).

The horse race feature requires per-user cost data. For enterprise accounts, `extra_usage` is the only available per-user dollar metric. This spec adds an "Enterprise Account" credential type that parses `extra_usage` and surfaces it as the primary usage indicator, while minimising changes to upstream files to keep merges clean.

---

## Goals

- Add a 4th credential type ("Enterprise Account") that reuses claude.ai session key auth but parses `extra_usage` from the `/usage` endpoint
- Map `extra_usage.utilization * 100` into the existing session percentage bar, relabelled "Monthly Spend"
- Make Enterprise connection a prerequisite for the horse race tab
- Minimise upstream file changes — new behaviour lives in new files wherever possible

---

## Upstream File Impact

| File | Change | Risk |
|------|--------|------|
| `Claude Usage/Shared/Models/Profile.swift` | Add `var connectionType: ConnectionType = .claudeAI` | Low — new field with default, Codable-safe |
| `Claude Usage/Shared/Services/UsageRefreshCoordinator.swift` | Add enterprise branch at fetch call site | Low — additive switch case |
| `Claude Usage/Views/SettingsView.swift` | Add `case enterprise` to `SettingsSection` | Low — same pattern as existing credential cases |

All other changes are in new files.

---

## New Files

| File | Responsibility |
|------|---------------|
| `Claude Usage/Shared/Models/ConnectionType.swift` | `ConnectionType` enum: `.claudeAI`, `.cliOAuth`, `.console`, `.enterprise` |
| `Claude Usage/Shared/Services/ClaudeAPIService+Enterprise.swift` | `fetchEnterpriseUsageData()` + `parseEnterpriseUsageResponse()` |
| `Claude Usage/Views/Settings/Credentials/EnterpriseCredentialsView.swift` | Settings UI for enterprise session key entry |

---

## Architecture

```
Profile.connectionType == .enterprise
  │
  ▼
UsageRefreshCoordinator
  ├── .enterprise → ClaudeAPIService.fetchEnterpriseUsageData()
  │                  → GET /organizations/{orgId}/usage
  │                  → parseEnterpriseUsageResponse()
  │                      reads extra_usage block only
  │                      → ClaudeUsage.sessionPercentage   (utilization * 100)
  │                      → ClaudeUsage.costUsed            (used_credits)
  │                      → ClaudeUsage.costLimit           (monthly_limit)
  │                      → ClaudeUsage.costCurrency        ("USD")
  │                      → all other fields: zero/nil
  │
  └── default → existing fetchUsageData() (unchanged)
```

---

## API

Same endpoint as the existing claude.ai flow:

```
GET https://claude.ai/api/organizations/{orgId}/usage
Cookie: sessionKey=...
```

Enterprise-relevant response block:
```json
{
  "five_hour": null,
  "seven_day": null,
  "extra_usage": {
    "is_enabled": true,
    "monthly_limit": 100000,
    "used_credits": 660.0,
    "utilization": 0.66,
    "currency": "USD"
  }
}
```

`parseEnterpriseUsageResponse()` reads only the `extra_usage` block. If `extra_usage` is null or `is_enabled` is false, throw a descriptive error prompting the user to check their account type.

**Field mapping:**

| `extra_usage` field | `ClaudeUsage` field | Notes |
|---------------------|---------------------|-------|
| `utilization * 100` | `sessionPercentage` | Displayed in the "Monthly Spend" bar |
| `used_credits` | `costUsed` | In cents |
| `monthly_limit` | `costLimit` | In cents |
| `currency` | `costCurrency` | "USD" |
| — | `sessionResetTime` | Set to end of current calendar month (last second of last day) |
| — | All weekly fields | Zero / nil |

---

## ConnectionType Enum

```swift
// Claude Usage/Shared/Models/ConnectionType.swift
enum ConnectionType: String, Codable {
    case claudeAI    // existing claude.ai session key
    case cliOAuth    // existing CLI OAuth
    case console     // existing Console API
    case enterprise  // NiCE Enterprise — parses extra_usage
}
```

---

## Profile Change

```swift
// One new field in Profile.swift, with default for backward compatibility
var connectionType: ConnectionType = .claudeAI
```

Existing profiles deserialise without the field and default to `.claudeAI`. No migration needed.

---

## UI Changes

### Session Bar Label

`SmartUsageDashboard` already reads `profileManager.activeProfile?.connectionType` for other display settings. When `connectionType == .enterprise`:

- Row title: `"Monthly Spend"` (instead of `"menubar.session_usage".localized`)
- Row subtitle: `nil` (instead of `"menubar.5_hour_window".localized`)
- Reset time: end of current calendar month (e.g. "Resets May 31")
- Weekly, Opus, Sonnet rows: hidden (data is nil/zero)

### Settings Sidebar

`SettingsSection` gains `case enterprise` in the credentials group:

- Title: `"Enterprise Account"`
- Icon: `"building.2.fill"`
- Routes to: `EnterpriseCredentialsView`

### EnterpriseCredentialsView

- Session key text field (same validation as `PersonalUsageView`)
- On connect: fetches org ID via `/organizations`, stores session key + org ID + `connectionType = .enterprise` on the active profile
- Shows current spend summary after successful connection

### Horse Race Prerequisite

`RaceTabView` adds a third state before "not configured":

```swift
// State priority: enterprise check → configured check → live/error
if activeProfile?.connectionType != .enterprise {
    // Show: "Horse Race requires an Enterprise Account connection"
    // [Open Settings] button → opens Settings to Enterprise credentials
}
```

Non-enterprise profiles never see the race tab content, with a clear explanation why.

---

## Out of Scope

- `omelette_promotional` data (not surfaced — unknown semantics)
- Auto-detection of enterprise mode from response shape
- Modifying the existing `parseUsageResponse()` function
- Changes to `MenuBarIconRenderer` (session % already drives the icon correctly)
