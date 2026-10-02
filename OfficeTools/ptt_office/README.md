# PTT Office — deployment runbook

Central collection UI for mirrored Project Time Tracker JSONL logs. REAPER
clients keep writing beside each `.rpp`; this service reads the **mirror** on a
share and aggregates totals in SQLite.

**Security:** The web UI has **no authentication**. Deploy only on a trusted
LAN (or behind a VPN / reverse proxy with auth). Do not expose port 8080 to the
public internet.

## Share layout (clients + office)

Create on the file server (example UNC `\\server\share\Zeiterfassung\`):

```
\\server\share\Zeiterfassung\
  ptt_config.json          ← copy from deploy/example_ptt_config.json, edit UNC
  timelogs\
    {project-guid}.timelog.jsonl
    ...
```

`deploy/example_ptt_config.json` matches the tracker package example
(`ProjectTimeTracker/deploy/example_ptt_config.json`): same keys and UNC
placeholder style.

On Windows, JSON string paths need doubled backslashes
(`\\server\...` → `\\\\server\\...` in the file).

### ACL notes

- **DAW Macs/PCs:** read/write `ptt_config.json` (read) and `timelogs\` (write
  mirror copies). They do not need access to the office SQLite DB.
- **Office ingest host:** read-only on `timelogs\` is sufficient if ingest only
  imports; the UI service account needs read on `timelogs\` and read/write on
  `PTT_SQLITE_PATH` parent directory.
- Use a dedicated `ptt` (or similar) Unix user for systemd units; map SMB
  credentials via `/etc/fstab` cifs mount or `credentials=` file — avoid
  storing passwords in unit files.

## Point each REAPER install at the config

Set ExtState once per machine (full path to `ptt_config.json` on the share):

```lua
reaper.SetExtState("ProjectTimeTracker", "ptt_config_path", "\\\\server\\share\\Zeiterfassung\\ptt_config.json", true)
```

See `ProjectTimeTracker/README.md` for mirror interval and failure behavior.

## Install on the office Linux host

### 1. Application tree

```bash
sudo mkdir -p /opt/ptt_office /var/lib/ptt_office
sudo chown ptt:ptt /var/lib/ptt_office
# Deploy checkout or copy OfficeTools/ptt_office to /opt/ptt_office
cd /opt/ptt_office
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
```

### 2. Mount mirrored timelogs

Mount the share so `PTT_TIMELOGS_DIR` points at the `timelogs` folder, e.g.:

```bash
# /mnt/zeiterfassung/timelogs → \\server\share\Zeiterfassung\timelogs
```

Edit `Environment=PTT_TIMELOGS_DIR` and `PTT_SQLITE_PATH` in
`deploy/ptt-office.service` and `deploy/ptt-office-ingest.service` if your
paths differ.

| Variable | Purpose |
|----------|---------|
| `PTT_TIMELOGS_DIR` | Directory containing `{guid}.timelog.jsonl` mirror files |
| `PTT_SQLITE_PATH` | SQLite database (ingest + web UI) |

### 3. systemd units

```bash
sudo cp deploy/ptt-office.service deploy/ptt-office-ingest.service deploy/ptt-office-ingest.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now ptt-office-ingest.timer
sudo systemctl enable --now ptt-office.service
```

Check:

```bash
systemctl status ptt-office-ingest.timer ptt-office.service
journalctl -u ptt-office-ingest.service -n 20
```

### 4. Manual ingest / refresh

Periodic import (preferred for production):

```bash
sudo -u ptt PTT_TIMELOGS_DIR=/mnt/zeiterfassung/timelogs \
  PTT_SQLITE_PATH=/var/lib/ptt_office/ptt_office.sqlite \
  /opt/ptt_office/.venv/bin/python -m ptt_office.ingest
```

From the UI: **Refresh** (`POST /refresh`) runs the same import inside the web
process. The timer keeps SQLite updated without hitting the UI.

## Run the web UI manually (dev)

```bash
export PTT_TIMELOGS_DIR=./timelogs
export PTT_SQLITE_PATH=./ptt_office.sqlite
uvicorn ptt_office.app:app --reload --host 127.0.0.1 --port 8080
```

## Tests

```bash
cd OfficeTools/ptt_office && pytest -q
```
