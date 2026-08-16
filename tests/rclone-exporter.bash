#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/remote" "$TMP/stage/payload"

cat >"$TMP/config.env" <<'CONFIG'
RCLONE_DESTINATION=remote:bucket
RETENTION_DAYS=14
MINIMUM_REDUNDANCY=2
CONFIG
printf 'archive\n' >"$TMP/stage/payload/base.tar.gz"
printf 'sum\n' >"$TMP/stage/checksums.sha256"
cat >"$TMP/stage/manifest.json" <<'JSON'
{"schema":1,"backup_name":"2026-08-02-006-axon","created_epoch":1785683663}
JSON

cat >"$TMP/bin/rclone" <<'RCLONE'
#!/usr/bin/env bash
set -Eeuo pipefail
map_path() { printf '%s/%s\n' "$TEST_REMOTE" "${1#remote:}"; }
command="$1"; shift
case "$command" in
    copy)
        source="$1"; destination="$(map_path "$2")"
        mkdir -p "$destination"
        cp -R "$source"/. "$destination"/
        rm -f "$destination/manifest.json"
        printf 'payload\n' >>"$TEST_LOG"
        ;;
    copyto)
        source="$1"; destination="$(map_path "$2")"
        mkdir -p "$(dirname "$destination")"; cp "$source" "$destination"
        printf 'manifest\n' >>"$TEST_LOG"
        ;;
    lsjson)
        root="$(map_path "$1")"
        find "$root" -type f -name manifest.json -printf '%P\n' | jq -Rn '[inputs | {Path:.}]'
        ;;
    cat) cat "$(map_path "$1")" ;;
    lsd) exit 0 ;;
    *) exit 64 ;;
esac
RCLONE
chmod +x "$TMP/bin/rclone"

run_exporter() {
    PATH="$TMP/bin:$PATH" TEST_REMOTE="$TMP/remote" TEST_LOG="$TMP/log" \
        EXPORTER_CONFIG="$TMP/config.env" "$ROOT/exporters/rclone/exporter" "$@"
}

run_exporter publish "$TMP/stage"
[[ "$(paste -sd, "$TMP/log")" == payload,manifest ]] || { echo "manifest was not uploaded last" >&2; exit 1; }
[[ "$(run_exporter latest-epoch)" == 1785683663 ]] || { echo "latest epoch mismatch" >&2; exit 1; }
[[ "$(run_exporter next-serial 2026-08-02)" == 7 ]] || { echo "serial mismatch" >&2; exit 1; }
