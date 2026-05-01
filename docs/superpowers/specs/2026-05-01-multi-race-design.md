# Multi-Race + Compiled View — Design Spec
_2026-05-01_

## Context

Sub-project 3 of 3 for the horse race feature. Sub-projects 1 (identity system) and 2 (race creation UI) are complete or in progress. This sub-project allows a client to join multiple races simultaneously and view a unified compiled standings track that deduplicates participants by display name, showing each person once at their best position across all races.

---

## Goals

- Join N races by pasting their URLs — push cost burn to all of them on every tick
- View a single compiled standings track (not one track per race)
- Same person in multiple races appears once, at their highest `percentUsed`
- Zero server changes required

---

## Storage — `RaceEntry` + `RaceSettings`

A new `RaceEntry` struct replaces the single `raceURL: String?`:

```swift
struct RaceEntry: Codable, Identifiable {
    let id: UUID        // local list identifier
    let url: String     // full race URL including slug
    var name: String?   // display name cached from server standings response
}
```

`RaceSettings` changes:

| Key | Before | After |
|-----|--------|-------|
| `"raceURL"` | `String?` — single race URL | **Removed** |
| `"raceName"` | `String?` — single race name | **Removed** |
| `"raceEntries"` | — | `[RaceEntry]` stored as JSON-encoded `Data` |

All other keys unchanged: `raceEnabled`, `serverBaseURL`, `participantID`, `participantName`, `pushInterval`, `pollInterval`.

### Migration from single-race

On first load after upgrade, if `raceEntries` is empty but the legacy `raceURL` key exists, migrate: read `raceURL` + `raceName`, create a single `RaceEntry`, save to `raceEntries`, remove the old keys. This is a one-time migration inside `RaceSettings.raceEntries` getter.

### Joining a race
User pastes a full race URL in Settings → app creates `RaceEntry(id: UUID(), url: pasted, name: nil)`, appends to the list, calls `RaceService.shared.restart()`. The display name is fetched lazily on first successful poll and written back into the entry.

### Leaving a race
Remove the `RaceEntry` from the list, call `RaceService.shared.restart()`.

---

## RaceService

Replaces single-race state with multi-race collections:

```swift
// Removed:
// @Published var standings: RaceStandings?

// Added:
@Published var allStandings: [String: RaceStandings] = [:]  // keyed by race URL
@Published var compiledStandings: [RaceParticipant] = []    // deduplicated, sorted
```

`lastError`, `lastPollDate` — unchanged.

### Poll cycle

Fetches all race URLs concurrently using `TaskGroup`:

```
async let results = TaskGroup {
    for entry in RaceSettings.shared.raceEntries {
        fetch GET {entry.url}/standings
        allStandings[entry.url] = result
        if result.name != entry.name → update entry.name in RaceSettings
    }
}
await results
compile()
lastPollDate = Date()
```

On per-race network error: set `lastError` for that race, continue polling others.

### Push cycle

Pushes to all race URLs concurrently using `TaskGroup`:

```
async let _ = TaskGroup {
    for entry in RaceSettings.shared.raceEntries {
        PUT {entry.url}/participant  (same payload as today)
    }
}
```

On per-race 403: mark that race's entry with an error state, stop pushing to it (do not stop pushing to other races).

### `compile()` — pure function

Deduplicates by display name (names are unique per race, enforced by the identity system). Keeps each person's entry with the highest `percentUsed`:

```swift
private func compile() {
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
    compiledStandings = best.values.sorted { $0.percentUsed > $1.percentUsed }
}
```

`compile()` is called after every poll cycle completes.

---

## Settings UI — `HorseRaceSettingsView`

The single URL field is replaced by a managed list:

```
Horse Race
──────────────────────────────────────
Enable Horse Race           [toggle]

Your Name                   [text field]

Races
  NICE-TEAM   server/races/abc…    [×]
  DEVS        server/races/xyz…    [×]
  [+ Join a race]

Timers
  Push every  [stepper]
  Poll every  [stepper]
```

**Race row:** shows `entry.name` once fetched, falls back to the URL. `[×]` removes the entry and restarts.

**"Join a race" action:** reveals an inline text field. User pastes the full URL and confirms. The app validates it is a non-empty string that starts with `http`, appends the entry, and restarts. No server round-trip at join time — name is populated on next poll.

**Sub-project 2 integration:** the `[+ Create race]` button (from sub-project 2) sits alongside `[+ Join a race]` and populates the list automatically after creation. The list UI is shared.

---

## RaceTabView

Minimal change — consumes `compiledStandings` instead of `standings?.participants`:

```swift
// Before:
ForEach(raceService.standings?.participants ?? []) { ... }

// After:
ForEach(raceService.compiledStandings) { ... }
```

The not-configured state now checks `RaceSettings.shared.raceEntries.isEmpty` instead of `raceURL == nil`.

The race header slug display falls back to showing the count of active races when multiple are joined (e.g. "3 races") rather than a single race name.

---

## Error Handling

| Condition | Behaviour |
|-----------|-----------|
| All races fail to poll | `lastError` set, error state shown in tab |
| One race fails, others succeed | Partial results shown, no error state — failed race simply absent from compiled view |
| 403 on push to one race | Stop pushing to that race, continue others, set per-race error (not global) |
| Empty race list | "No races configured" state shown |

---

## Out of Scope (MVP)

- Reordering races in the list
- Per-race enable/disable toggle
- Showing which race a participant's best % came from
- Race-specific error indicators in the list
