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

## Install via ReaPack (recommended)

1. In REAPER: Extensions → ReaPack → Import repositories
2. Paste: `https://github.com/Woscht/GW_Reapack1/raw/main/index.xml`
3. Confirm — repository name should appear as **GW_Reapack1**
4. Extensions → ReaPack → Browse packages, filter for `ProjectTimeTracker`, Install
5. Actions are registered automatically; bind to toolbar/shortcut as desired

## Usage

- **Start action** (`ProjectTimeTracker.lua`): run once → tracking starts.
- **Stop action** (`ProjectTimeTracker_Stop.lua`): stops tracking without the task-control dialog.
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
