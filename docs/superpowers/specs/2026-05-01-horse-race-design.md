# Horse Race Feature — Design Spec
_2026-05-01_

## Context

Claude Usage is a macOS menubar app that tracks Claude API usage (session %, weekly %, cost) for one or more local profiles. Each profile stores credentials locally; the app pulls usage data from Claude's APIs on a refresh timer.

This feature adds a **horse race** mode: team members on the same enterprise spend cap can publish their cost burn to a shared remote API and watch each other's progress in real time — visualised as horses on a track in the popover.

---

## Goals

- Let N people on the same $1000/month enterprise plan race each other to the spend cap
- No accounts, no server setup required to join — just a shared race URL
- Minimal impact on existing functionality
- Frontend is portable: swapping the base URL moves from debug server to production

---

## Architecture

```
Local App                              Remote API
──────────────────────────────         ────────────────────────
RaceService
  ├── push timer (60s)  ────────────►  PUT {raceUrl}/participant
  │     { name, cost_used_cents,
  │       cost_limit_cents, updated_at }
  │
  ├── poll timer (30s)  ◄────────────  GET {raceUrl}/standings
  │     [{ name, cost_used_cents,        → sorted by % desc
  │        cost_limit_cents, updated_at }]
  │
  └── manual refresh (user-triggered) ► GET {raceUrl}/standings

RaceSettings (UserDefaults)
  ├── raceURL: String?           ← full URL including race slug
  ├── participantName: String    ← default: macOS hostname
  ├── pushInterval: TimeInterval ← default 60s
  ├── pollInterval: TimeInterval ← default 30s
  └── raceEnabled: Bool          ← default false
```

**Key decisions:**
- `RaceService` is a new standalone service — no coupling to `ClaudeAPIService`, `ProfileManager`, or the existing refresh loop
- It reads cost data from the active profile's `APIUsage`: `cost_used_cents = currentSpendCents`, `cost_limit_cents = currentSpendCents + prepaidCreditsCents`. Falls back to `ClaudeUsage.costUsed / costLimit` (extra usage) if `APIUsage` is nil
- Push only fires if cost data is non-nil and `raceEnabled == true` and `raceURL` is set
- No race URL configured → race tab shows not-configured prompt, zero network activity

---

## API Contract

Base URL is the full race URL, e.g. `http://localhost:8765/races/NICE-TEAM`. The slug is embedded in the URL — no separate race code field.

### Push participant

```
PUT {raceUrl}/participant
Content-Type: application/json

{
  "name": "Ben",
  "cost_used_cents": 42300,
  "cost_limit_cents": 100000,
  "updated_at": "2026-05-01T14:23:00Z"
}

Responses:
  200 OK          — participant updated
  400 Bad Request — malformed payload
  404 Not Found   — race slug not found (production server may require prior creation; debug server auto-creates)
```

### Get standings

```
GET {raceUrl}/standings

Response 200 OK:
{
  "race_slug": "NICE-TEAM",
  "participants": [
    {
      "name": "Alice",
      "cost_used_cents": 61500,
      "cost_limit_cents": 100000,
      "updated_at": "2026-05-01T14:20:00Z"
    },
    {
      "name": "Ben",
      "cost_used_cents": 42300,
      "cost_limit_cents": 100000,
      "updated_at": "2026-05-01T14:23:00Z"
    }
  ]
}
```

**Notes:**
- Costs are **integers in cents** — avoids float precision issues, consistent with existing `costUsed`/`costLimit` fields in the app
- `cost_limit_cents` is pushed per-participant — server stores it as-is, clients use it for % calculation
- Participants are sorted by `cost_used_cents / cost_limit_cents` descending (leader first)
- The debug server auto-creates a race on first PUT — no prior setup needed

---

## Data Model

```swift
struct RaceParticipant: Codable, Identifiable {
    var id: String { name }
    let name: String
    let costUsedCents: Int
    let costLimitCents: Int
    let updatedAt: Date

    var percentUsed: Double {
        guard costLimitCents > 0 else { return 0 }
        return Double(costUsedCents) / Double(costLimitCents) * 100.0
    }

    var isStale: Bool {
        Date().timeIntervalSince(updatedAt) > 300  // 5 minutes
    }
}

struct RaceStandings: Codable {
    let raceSlug: String
    let participants: [RaceParticipant]
}
```

---

## UI — Popover Tab

The popover gains a **tab bar** at the top. Two tabs: `Usage` (existing view, unchanged) and `🏇 Race`. Active tab is persisted in UserDefaults. Default: `Usage`.

### Race tab — three states

**Not configured:**
```
🏇 Horse Race
──────────────────────────────
  [horse emoji]
  No race configured.
  Add a race URL in Settings → Horse Race
  [Open Settings]
```

**Live:**
```
🏇 NICE-TEAM                         [↺]
────────────────────────────────────────
  Alice  ----🐴---------🏁
  Ben    --------🐴-----🏁       ← your row (brighter track)
  Carol  🐴--------------🏁
  Dave   🐴--------------🏁      ← stale: name + track + horse + flag all greyed
────────────────────────────────────────
  Updated 12s ago · hover for details
```

**Visual rules:**
- One lane per participant, sorted leader-first (highest % at top)
- Track: dashed horizontal line spanning the lane
- Horse emoji `🐴` positioned at `percentUsed %` along the track (left = 0%, right = 100%)
- Finish flag `🏁` at right edge of each lane
- Your row: track dashes slightly brighter than others
- Stale (> 5 min): name, track dashes, horse, and flag all dimmed to ~20% opacity, greyscale horse — no icons or badges
- Hover on horse → tooltip: `"Alice · $615 · 61% · 2m ago"` (or `"last seen Xm ago"` if stale)

**Error state:**
```
  Could not reach race server.
  [Retry]
```

---

## Settings — Horse Race Section

New section in the existing Settings window (alongside existing sections).

| Field | Type | Default |
|-------|------|---------|
| Enable Horse Race | Toggle | Off |
| Race URL | Text field | `""` |
| Your display name | Text field | macOS hostname |
| Push every | Stepper (10s–300s) | 60s |
| Poll every | Stepper (10s–300s) | 30s |

Race URL is the full URL including slug, e.g. `http://localhost:8765/races/NICE-TEAM`. Changing it to a production URL requires no code changes.

---

## Debug Server

Single Python file. Runs on a configurable port (default `8765`). In-memory state — resets on restart.

**Endpoints:**
- `PUT /races/{slug}/participant` — upserts participant; auto-creates race if slug not found
- `GET /races/{slug}/standings` — returns all participants sorted by % descending

**Usage:**
```bash
python3 debug_race_server.py          # default port 8765
python3 debug_race_server.py --port 9000
```

**Location:** `debug/debug_race_server.py` in the repo root.

---

## File Structure

```
Claude Usage/
  Shared/
    Models/
      RaceParticipant.swift       ← data model + isStale logic
    Services/
      RaceService.swift           ← push/poll timers, manual refresh
    Storage/
      RaceSettings.swift          ← UserDefaults keys + defaults
  Views/
    MenuBar/
      RaceTabView.swift           ← horse race tab UI (3 states)
    Settings/
      App/
        HorseRaceSettingsView.swift ← settings section
debug/
  debug_race_server.py            ← local test server
```

---

## Out of Scope (MVP)

- Authentication / access control on the remote API
- Persistent server implementation (that's a future service)
- Push notifications when someone overtakes you
- Historical race data / charts
- Multiple simultaneous races per profile
