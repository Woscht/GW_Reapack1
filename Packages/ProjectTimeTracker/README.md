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
2. Run **`Project Time Tracker: Always-on aktivieren`** once (writes `Scripts/__startup.lua` and starts the tracker now).
3. To undo: run **`Project Time Tracker: Always-on deaktivieren`**.
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

For always-on: run **Always-on aktivieren** once (or edit `Scripts/__startup.lua` manually).

## Usage

- **Start:** `ProjectTimeTracker.lua` (defer loop)
- **Always-on on/off:** `ProjectTimeTracker_EnableAlwaysOn.lua` / `ProjectTimeTracker_DisableAlwaysOn.lua`
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

- Saved project: `{project_dir}/timetracker/{guid}.timelog.jsonl`
  (new logs only; older files beside the `.rpp` are left untouched)
- Untitled: `{resource}/PTT_untitled_{pid}.timelog.jsonl` until first save

- Untitled: temp under REAPER resource path, migrated on first save
- Save As / version rename in **same folder**: same GUID → same log (times continue)
- Save into **new folder**: log copied, old renamed to `.bak`

## Central timelog mirror (optional)

Office can collect copies of per-project JSONL logs on a shared drive. The file
beside each `.rpp` stays the **source of truth**; the share is a read-only
mirror for merge/reporting (e.g. OfficeTools).

### Share layout

Place one shared config and a folder for mirrored logs (create `timelogs` on the
share; clients do not write `ptt_config.json`):

```
\\server\share\Zeiterfassung\
  ptt_config.json
  timelogs\
    {project-guid}.timelog.jsonl
    ...
```

Example config (placeholders): `deploy/example_ptt_config.json` in this repo.

```json
{
  "central_timelogs_dir": "\\\\server\\share\\Zeiterfassung\\timelogs",
  "mirror_interval_s": 300,
  "mirror_save_debounce_s": 30,
  "mirror_enabled": true,
  "notes_ui_base_url": "http://dispodisco-host:3001",
  "notes_auto_open": true
}
```

### Nicht ins Büro (opt-out)

Action **Project Time Tracker: Toggle Nicht ins Büro** marks the **current saved project**
(ExtState `office_opt_out=1`). While set:

- no mirror to the central timelogs folder  
- no hydrate from central  
- no notes auto-open  

Local logging under `timetracker/` continues. Toggle again to clear the flag.
Untitled projects are never mirrored anyway. If a project was already mirrored before
opt-out, hide it in DispoDisco with **Löschen** if needed.

### Block notes (DispoDisco)

- Local sidecar: `{project}/timetracker/{guid}.notes.jsonl` (copied to central as `{guid}.notes.jsonl` when present).
- `notes_ui_base_url`: office UI base (empty disables the dialog and the Open notes action).
- `notes_auto_open`: when true, on tracker stop / project close / project switch PTT queries
  `{base}/projects/{guid}/notes/status?machine=&since=` and shows an in-REAPER **Projektdoku**
  dialog (with project name) if the current occupancy has an undocumented Edit and/or Recording block.
  ReaImGui is used when installed; otherwise `GetUserInputs`. Status HTTP failure → no dialog.
- Manual action: **Project Time Tracker: Open notes UI** always opens
  `{base}/projects/{guid}/notes?src=reaper` (for older undocumented blocks).
- Recommended: install **ReaImGui** from ReaPack on studio DAWs.

On Windows UNC paths in JSON need doubled backslashes (`\\` → `\\\\` in the file).

### Point REAPER at the config

**Studio default (Temp test folder):** `2.1.2+` looks for the first readable config:

- **macOS (DAWs):** `/Volumes/PRODUKTION/01_Projekte/_Temp/ptt_e2e/ptt_config.json`  
  Connect in Finder: `smb://192.168.203.33/PRODUKTION` — the volume name must be **PRODUKTION**.
- **Windows:** `\\192.168.203.33\PRODUKTION\01_Projekte\_Temp\ptt_e2e\ptt_config.json`
- **Linux office:** `/mnt/cube/01_Projekte/_Temp/ptt_e2e/ptt_config.json`

On Mac, `central_timelogs_dir` may be UNC **or** the Linux mount `/mnt/cube/...`;
the tracker maps both to `/Volumes/PRODUKTION/...`. On Linux, `/Volumes/PRODUKTION/...`
is mapped to `/mnt/cube/...`.
No ExtState needed if the share is mounted and `ptt_config.json` exists.

Optional override (other shares / machines):

```lua
reaper.SetExtState("ProjectTimeTracker", "ptt_config_path", "\\\\server\\share\\Zeiterfassung\\ptt_config.json", true)
```

Load order: ExtState `ptt_config_path` (if set), then `PTT.config.CANDIDATE_PATHS`,
else built-in defaults (mirror disabled when `central_timelogs_dir` is empty).

### Mirror behavior

- **Forced** copy (full local log → share) when:
  - the tracker **starts** (script open);
  - you **save** the project (dirty → clean), debounced by `mirror_save_debounce_s`
    (default **30** seconds between forced save mirrors);
  - the **project identity** changes (switch project, save-as, path/GUID migrate);
  - the tracker **stops** (`ProjectTimeTracker_Stop` or shutdown path);
  - **best effort** when a saved project is closed and REAPER shows an empty/untitled
    project (not on initial untitled startup).
- While the tracker runs, an **interval** copy still runs about every **5 minutes**
  (`mirror_interval_s`, default 300) as a safety net.
- Transport **Play/Stop** does **not** trigger a mirror.
- Copies are **atomic**: write `dest.tmp`, then rename/replace `dest` so
  readers never see a half-written file.
- If the share is **unreachable**, tracking and local JSONL writes continue
  unchanged; mirror failures are skipped and a console warning may appear (rate
  limited, about every 5 minutes). When the share is back, the next successful
  mirror overwrites the central file with the full local log.

## Limitations (Phase 1)

- No toolbar UI yet
- No live central DB/browser sync (`sync_hook` is a no-op); optional SMB mirror only
- Multi-instance writers not supported

## Tests

```bash
# requires Lua 5.4 on PATH as lua5.4
cd Packages/ProjectTimeTracker && lua5.4 tests/run_tests.lua
```
