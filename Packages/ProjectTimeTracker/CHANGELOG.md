# Changelog

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
