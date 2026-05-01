# Race Identity System — Design Spec
_2026-05-01_

## Context

The initial race server uses participant display name as both the identity and the Redis key. This allows name collisions (two people named "Ben") and gives any client write access to any participant's record. This spec adds a proper identity layer: each client holds a private UUID, display names are claimed atomically, and only the name's owner can push data under it.

This is sub-project 1 of 3. Sub-projects 2 (race creation UI) and 3 (multiple races + compiled view) depend on this foundation.

---

## Goals

- Prevent name collisions — two clients cannot share a display name in the same race
- Ensure only the identity holder can push data under their name
- Preserve name ownership across monthly usage resets
- Support atomic rename without breaking the standings for other viewers
- Silent re-registration after monthly reset — no user action required unless their name was taken

---

## Redis Schema

Four key types per race (two existing, two new):

| Key | Type | Fields / Value | TTL |
|-----|------|---------------|-----|
| `race:{slug}:meta` | Hash | `name`, `created_at` | 60 days, refreshed on activity |
| `race:{slug}:names` | Hash | `{display_name} → {client_uuid}` | 60 days, **never cleared on monthly reset** |
| `race:{slug}:p:{name}` | Hash | `name`, `cost_used_cents`, `cost_limit_cents`, `updated_at` | 60 days, **cleared on monthly reset** |
| `race:{slug}:epoch:{YYYY-MM}` | String | `"1"` | TTL = seconds until 00:00 GMT on 1st of next month |

### Monthly Reset (lazy)

Triggered on every PUT and GET /standings request:

1. Check `EXISTS race:{slug}:epoch:{current_YYYY-MM}`.
2. If the key is **missing** → a monthly reset is due:
   - Delete all `race:{slug}:p:*` keys (usage data).
   - Create `race:{slug}:epoch:{YYYY-MM}` with TTL = seconds until 00:00 GMT on the 1st of next month.
   - `race:{slug}:names` is left untouched — name ownership survives.
3. If the key **exists** → no reset needed, proceed normally.

### Re-registration After Reset

After a reset, a client's next PUT includes their `id`. The server checks the names hash:
- `names[name] == id` → still the owner (ownership survived reset). PUT proceeds.
- `names[name] == other_id` → name was claimed by someone else during the gap. Returns 403.
- `names[name]` missing → name was never registered this race (shouldn't happen in normal flow). Returns 403.

---

## API

### POST /races/{slug}/register — New

Claim a display name for a client UUID. Idempotent: same `(id, name)` always succeeds.

```
POST /races/{slug}/register
Content-Type: application/json

{ "id": "a3f9c2d1-...", "name": "Ben" }

→ 200 OK        { "status": "ok" }          — registered or no-op
→ 409 Conflict  { "detail": "Name taken" }  — name owned by different id
→ 404 Not Found                              — race slug not found
```

Implementation: `HSETNX race:{slug}:names {name} {id}`.
- Returns 1 (claimed) or 0 (already exists). If 0, read current owner — if same `id`, return 200 (idempotent). If different `id`, return 409.

### PUT /races/{slug}/participant — Modified

Adds `id` field. Validates ownership before writing. Also triggers lazy reset check.

```
PUT /races/{slug}/participant
Content-Type: application/json

{
  "id": "a3f9c2d1-...",
  "name": "Ben",
  "cost_used_cents": 42300,
  "cost_limit_cents": 100000,
  "updated_at": "2026-05-01T14:23:00Z"
}

→ 200 OK         { "status": "ok" }
→ 403 Forbidden  { "detail": "ID does not match name owner" }
→ 404 Not Found  race not found
→ 400            malformed payload
```

### POST /races/{slug}/participant/rename — New

Atomically renames a participant. Frees the old name for others.

```
POST /races/{slug}/participant/rename
Content-Type: application/json

{ "id": "a3f9c2d1-...", "old_name": "Ben", "new_name": "Benjamin" }

→ 200 OK         { "status": "ok" }
→ 403 Forbidden  — id does not own old_name
→ 409 Conflict   — new_name already taken by a different id
→ 404 Not Found  — race slug not found
```

Implementation (Lua script for atomicity — `HSETNX` + `RENAME` cannot be safely combined in a plain pipeline):
1. Check `HGET names {old_name}` == `id` → 403 if not.
2. `HSETNX names {new_name} {id}` → if 0 and owner ≠ id → 409. Abort.
3. `HDEL names {old_name}`.
4. `RENAME race:{slug}:p:{old_name} race:{slug}:p:{new_name}`.
5. `HSET race:{slug}:p:{new_name} name {new_name}`.

Steps 1–5 execute in a single Lua script (`r.eval(...)`) to ensure atomicity. If new_name is taken, script returns early before any data is moved.

### GET /races/{slug}/standings — Unchanged

Response shape unchanged. Also triggers lazy reset check before reading participant data.

---

## Client Changes (Swift)

### RaceSettings — New field

```swift
var participantID: String {
    get {
        let stored = defaults.string(forKey: Keys.participantID) ?? ""
        if stored.isEmpty {
            let newID = UUID().uuidString
            defaults.set(newID, forKey: Keys.participantID)
            return newID
        }
        return stored
    }
}
// No setter — ID is generated once and never changes
```

Key: `"raceParticipantID"`. Generated lazily on first read. Persists forever.

### RaceService — Changes

- `start()` calls `register()` after `push()` and `poll()` timers are scheduled. Registration is fire-and-forget on first launch.
- `push()` payload gains `"id": RaceSettings.shared.participantID`.
- On 403 from PUT → set `lastError = "Name conflict — update your name in Settings"`, stop pushing.
- `register()` — new async func: `POST /races/{slug}/register` with `{id, name}`. On 409 → set `lastError = "Name taken — choose a different name in Settings"`.

### HorseRaceSettingsView — Rename on name change

When `participantName` changes (on submit, not on every keystroke):
1. If previously registered in a race → call rename API with `(id, old_name, new_name)`.
2. On 409 → show inline error "Name already taken", revert field.
3. On success → update `RaceSettings.shared.participantName`.

If not yet registered (first setup), just save the name — registration happens on next push.

---

## Error States in Race Tab

| Condition | Error shown |
|-----------|-------------|
| 403 on PUT | "Name conflict — update your name in Settings" |
| 409 on register | "Name taken — choose a different name in Settings" |
| 409 on rename | Inline in Settings field: "Name already taken" |
| Network error | Existing error state (unchanged) |

---

## Out of Scope (this sub-project)

- Race creation UI (sub-project 2)
- Multiple races / compiled view (sub-project 3)
- ID recovery if UserDefaults is cleared (treat as new participant)
- Admin tools for manually freeing a claimed name
