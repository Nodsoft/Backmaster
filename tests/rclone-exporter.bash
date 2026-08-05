#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/remote" "$TMP/stage/payload"

cat >"$TMP/config.env" <<'CONFIG'
RCLONE_DESTINATION=remote:bucket
RETENTION_DAYS=1
MINIMUM_REDUNDANCY=2
WAL_RETENTION_DAYS=15
CONFIG
printf 'archive\n' >"$TMP/stage/payload/base.tar.gz"
printf 'sum\n' >"$TMP/stage/checksums.sha256"
cat >"$TMP/stage/manifest.json" <<'JSON'
{"schema":1,"backup_name":"2026-08-02-006-axon","created_epoch":1785683663}
JSON

for entry in '2026-08-02-005-myelin 1785500000' \
    '2026-07-20-004-axon 1784500000'; do
    read -r name epoch <<<"$entry"
    mkdir -p "$TMP/remote/bucket/basebackups/$name"
    printf '{"schema":1,"backup_name":"%s","created_epoch":%s}\n' \
        "$name" "$epoch" \
        >"$TMP/remote/bucket/basebackups/$name/manifest.json"
done

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
    purge)
        destination="$(map_path "$1")"
        rm -rf -- "$destination"
        printf 'purge %s\n' "$1" >>"$TEST_LOG"
        ;;
    delete)
        printf 'delete %s %s\n' "$1" "$*" >>"$TEST_LOG"
        ;;
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

run_exporter retain
[[ -d "$TMP/remote/bucket/basebackups/2026-08-02-005-myelin" ]]
[[ ! -e "$TMP/remote/bucket/basebackups/2026-07-20-004-axon" ]]
grep 'delete .*objects/wal.*--min-age 15d' "$TMP/log" >/dev/null || {
    echo "WAL retention was not applied" >&2
    exit 1
}

sed -i 's/^RETENTION_DAYS=1$/RETENTION_DAYS=unlimited/' "$TMP/config.env"
sed -i 's/^WAL_RETENTION_DAYS=15$/WAL_RETENTION_DAYS=none/' "$TMP/config.env"
: >"$TMP/log"
run_exporter retain
[[ ! -s "$TMP/log" ]] || {
    echo "unlimited retention still removed remote data" >&2
    exit 1
}

sed -i 's/^RETENTION_DAYS=unlimited$/RETENTION_DAYS=invalid/' "$TMP/config.env"
if run_exporter retain >/dev/null 2>&1; then
    echo "invalid retention was accepted" >&2
    exit 1
fi

echo "rclone exporter tests passed"
