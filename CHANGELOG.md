# Changelog

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
