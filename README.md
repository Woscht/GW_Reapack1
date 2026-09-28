# ProjectTimeTracker

Reaper script that tracks **recording time** and **editing time** per project —
for client billing and voice-actor payroll. Pure stock Lua (ReaScript), no
extensions required.

## Install (once per Mac)

1. Copy `ProjectTimeTracker.lua` into REAPER's Scripts folder
   (macOS: `~/Library/Application Support/REAPER/Scripts/`).
   For auto-start on every launch, put it in `Scripts/Startup/` instead.
2. In Reaper: **Actions → Show action list → New action → Load ReaScript**,
   pick the file. Bind it to a toolbar button or shortcut if you like.

## Usage

## Install via ReaPack (recommended)

1. In REAPER: Extensions → ReaPack → Manage repositories
2. Click Import and paste: [https://raw.githubusercontent.com/Woscht/GW_Reapack1/main/index.xml]
3. Click OK to add the repository
4. Still in Manage repositories, type "ProjectTimeTracker" in the filter box
5. Select the package and click Install
6. The actions will be available in the action list; bind to toolbar/shortcut as desired


- **Start action** (`ProjectTimeTracker.lua`): run once → tracking starts.
- **Stop action** (`ProjectTimeTracker_Stop.lua`): load this too (Actions → Load ReaScript)
  and run it to stop — avoids REAPER's task-control dialog entirely.
- Export actions: run the script and choose via the Actions list, or call
  `export_report("md")` / `export_report("csv")`. Reports are written next to
  the `.rpp` as `<project>-report.md/.csv`.

## How it works

- Polls transport/edit-cursor/undo state every 1.5 s.
- Recording sessions: first take to last take, gaps ≤ 15 min included.
- Editing proxy: play/pause/cursor movement/undo changes while not recording.
- Events append as JSONL to `<GUID>.timelog.jsonl` next to the `.rpp`
  (log identity is the project GUID, so renaming/moving the `.rpp` keeps history).

## Reports

Markdown (human) and CSV (machine) with per-machine totals and recording-session spans.
