# Changelog

## 2.2.0 — 2026-10-06

- End-of-session **Arbeitskommentar** dialog (ReaImGui; `GetUserInputs` fallback)
- Prompts only the latest undocumented Edit/Recording of this occupancy; older gaps as a hint
- Speichern writes the local notes sidecar then copies that file for the captured GUID; Ohne Kommentar once per leave
- Removed browser auto-open on stop/switch (manual Open notes UI remains)
- ReaImGui recommended via ReaPack, not a hard `@requires`

## 2.1.11 — 2026-10-05

- Console warnings when `notes_ui_base_url` is empty, notes status is unreachable, or notes UI opens
- Notes status HTTP timeout default 3s (NFS / office reingest headroom)

## 2.1.10 — 2026-10-05

- Map shared `central_timelogs_dir` `/mnt/cube/...` → `/Volumes/PRODUKTION/...` on Mac (fixes mkdir failed when DAWs load the Linux path from studio config)
- Mirror warning now includes the destination path

## 2.1.9 — 2026-10-05

- Skip mirror and hydrate for **unsaved/untitled** projects (fixes `[PTT] mirror warning: mkdir failed` spam)

## 2.1.8 — 2026-10-05

- Action **Toggle Nicht ins Büro**: sets project ExtState `office_opt_out`
- While opted out: no central mirror, no hydrate, no notes auto-open; local JSONL continues
- Toggle again to re-enable office sync for that project

## 2.1.7 — 2026-10-05

- Mirror local `{guid}.notes.jsonl` beside timelogs (always overwrite when local notes exist; never delete central if local missing)
- Config: `notes_ui_base_url`, `notes_auto_open` (default true)
- Auto-open DispoDisco notes UI on stop / project switch only when `/notes/status` reports `missing > 0` (rate-limited; no open if status fails)
- New action: **Project Time Tracker: Open notes UI** (always opens)

## 2.1.6 — 2026-10-02

- Heartbeat/checkpoint write `span_accum` / `rec_accum` (save + rec-stop + heartbeat) so crash recovery and live mirrors keep progress; billing still only from session/rec end
- Mirror: never overwrite central with a shorter local log; hydrate local from central when missing/shorter (local→SMB continue)

## 2.1.5 — 2026-10-02

- Heartbeat while active every **3 minutes** (was 30 s) — fewer JSONL lines; billing metrics unchanged

## 2.1.4 — 2026-10-02

- Local JSONL for saved projects: `{project_dir}/timetracker/{guid}.timelog.jsonl` (no auto-migrate of older beside-.rpp logs)
- Force mirror on open, debounced manual save (~30s), project switch, tracker stop, best-effort project close
- Config: `mirror_save_debounce_s` (default 30); 5 min interval remains safety net

## 2.1.3 — 2026-10-02

- Force mirror on open, debounced manual save (~30s), project switch, tracker stop, best-effort project close
- Config: mirror_save_debounce_s (default 30); 5 min interval remains safety net

## 2.1.2 — 2026-10-02

- macOS: config candidate `/Volumes/PRODUKTION/.../ptt_config.json`
- Map `central_timelogs_dir` UNC → `/Volumes/PRODUKTION/...` on Mac
- Console message when mirror is enabled but config/central path is missing

## 2.1.1 — 2026-10-02

- Ship studio default `CANDIDATE_PATHS` for Cube Temp test folder (`ptt_e2e/ptt_config.json`)
- ExtState `ptt_config_path` remains an optional override

## 2.1.0 — 2026-10-02

- Optional central timelog mirror to a shared folder (`central_timelogs_dir`)
- Config via ExtState `ptt_config_path` or `modules/config.lua` candidate paths
- Mirror on interval (default 5 min) and forced copy on script stop
- Atomic copy (`mirror.lua`); local JSONL remains authoritative on share failure

## 2.0.0 — 2026-09-28

- Clean-core modular rewrite (`modules/`)
- Dual metrics: Session-Span + Rec-Rolling
- Pause counts as inactive; Play/Record/interaction active
- Idle grace 2 min; session/rec gaps 15 min
- Heartbeat every 30 s while active
- Untitled temp log → migrate on save
- Path change: copy log + `.bak`
- Crash recovery closes at last activity timestamp
- JSONL-only totals; machine id is hostname helper only
- sync_hook stub for future DB

## 1.0.0

- Initial verified release (prototype monolith)
