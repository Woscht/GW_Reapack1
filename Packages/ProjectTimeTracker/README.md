# ProjectTimeTracker (v2 clean-core)

REAPER script that logs **Session-Span** and **Rec-Rolling** per project GUID —
for gage and client billing. Stock Lua only. JSONL beside the `.rpp` is the
source of truth.

Design: `docs/superpowers/specs/2026-09-28-project-time-tracker-clean-core-design.md`
(in the Zeiterfassung workspace).

## Install

### ReaPack (recommended)

1. Install [ReaPack](https://reapack.com) if it is not already installed.
2. In REAPER: **Extensions → ReaPack → Import repositories…**
3. Paste this index URL and confirm:

   ```
   https://github.com/Woscht/GW_Reapack1/raw/main/index.xml
   ```

4. **Extensions → ReaPack → Browse packages…**
5. Search for **Project Time Tracker** (or `ProjectTimeTracker`).
6. Right‑click → **Install** (installs the entry script, Stop action, and all `modules/*.lua` files).
7. **Extensions → ReaPack → Synchronize packages** if the package does not appear yet (CDN can lag briefly after a push).

#### Always-on (startup)

1. **Actions → Show action list**
2. Find `Script: ProjectTimeTracker.lua` (name may vary slightly by REAPER/ReaPack).
3. Add it to the **startup actions** / start queue so tracking starts with every REAPER launch.
4. Optionally bind `ProjectTimeTracker_Stop.lua` to a shortcut for emergency stop.

#### Verify install

After install, the Scripts folder (under the ReaPack package path) should contain:

- `ProjectTimeTracker.lua`
- `ProjectTimeTracker_Stop.lua`
- `modules/` (`util.lua`, `activity.lua`, `bootstrap.lua`, …)

If `modules/` is missing, synchronize ReaPack again or reinstall the package.

### Manual

Copy `ProjectTimeTracker.lua`, `ProjectTimeTracker_Stop.lua`, and the entire
`modules/` folder into REAPER Scripts (same relative layout).

For always-on: add `ProjectTimeTracker.lua` to the **startup actions** queue
(Actions → Show action list → Options / startup).

## Usage

- **Start / always-on:** `ProjectTimeTracker.lua` (defer loop)
- **Emergency stop:** `ProjectTimeTracker_Stop.lua` (sets ExtState; no dialog)
- Totals print to the console on stop; full history remains in JSONL

## Metrics

| Metric | Meaning |
|--------|---------|
| **Session-Span** | Active work time (Play / Record / interaction) + up to 2 min idle grace; new session after 15 min idle |
| **Rec-Rolling** | Seconds while transport is recording; rec session ends after 15 min without recording |

**Pause = inactive.** Interaction = cursor move, dirty/undo change, or track/item selection change.

Office chooses which metric to bill. `machine` is informational only.

## Logs

- Saved project: `{project_dir}/{guid}.timelog.jsonl`
- Untitled: temp under REAPER resource path, migrated on first save
- Save As / version rename in **same folder**: same GUID → same log (times continue)
- Save into **new folder**: log copied, old renamed to `.bak`

## Limitations (Phase 1)

- No toolbar UI yet
- No central DB/browser sync yet (`sync_hook` is a no-op)
- Multi-instance writers not supported

## Tests

```bash
# requires Lua 5.4 on PATH as lua5.4
cd Packages/ProjectTimeTracker && lua5.4 tests/run_tests.lua
```
