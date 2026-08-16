#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin"
cat >"$TMP/config.env" <<'CONFIG'
AZURE_DESTINATION=https://example.blob.core.windows.net/backups
BARMAN_SERVER_NAME=test
PGHOST=/var/run/postgresql
PGPORT=5431
PGUSER=postgres
CONFIG
cat >"$TMP/bin/barman-cloud-backup-list" <<'BARMAN'
#!/usr/bin/env bash
cat <<'JSON'
[
  {"backup_name":"2026-08-02-001-axon","status":"DONE"},
  {"name":"2026-08-02-006-myelin","status":"DONE"},
  {"backup_name":"2026-08-01-099-axon","status":"DONE"},
  {"backup_name":"2026-08-02T151423Z-axon","status":"DONE"}
]
JSON
BARMAN
chmod +x "$TMP/bin/barman-cloud-backup-list"

actual="$(PATH="$TMP/bin:$PATH" DRIVER_CONFIG="$TMP/config.env" \
    "$ROOT/drivers/postgres/driver" next-serial 2026-08-02)"
[[ "$actual" == 7 ]] || {
    printf 'expected serial 7, got %s\n' "$actual" >&2
    exit 1
}

