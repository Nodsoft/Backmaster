#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT
temporary="$(mktemp -d)"
readonly temporary
trap 'rm -rf -- "$temporary"' EXIT
mkdir -p "$temporary/bin" "$temporary/remote/basebackups" \
    "$temporary/stage/payload"

cat >"$temporary/config.env" <<'CONFIG'
AZCOPY_DESTINATION=https://account.blob.core.windows.net/backups/backmaster
AZCOPY_SAS_TOKEN=sig=test
RETENTION_DAYS=1
MINIMUM_REDUNDANCY=2
HEALTHCHECK_MAX_AGE_SECONDS=129600
WAL_RETENTION_DAYS=15
CONFIG
printf 'archive\n' >"$temporary/stage/payload/base.tar.gz"
printf 'space\n' >"$temporary/stage/payload/space name"
printf 'sum\n' >"$temporary/stage/checksums.sha256"
cat >"$temporary/stage/manifest.json" <<'JSON'
{"schema":1,"backup_name":"2026-08-02-006-axon","created_epoch":1785683663}
JSON

for entry in '2026-08-02-005-myelin 1785500000' \
    '2026-07-20-004-axon 1784500000'; do
    read -r name epoch <<<"$entry"
    mkdir -p "$temporary/remote/basebackups/$name"
    printf '{"schema":1,"backup_name":"%s","created_epoch":%s}\n' \
        "$name" "$epoch" \
        >"$temporary/remote/basebackups/$name/manifest.json"
done

cat >"$temporary/bin/azcopy" <<'AZCOPY'
#!/usr/bin/env bash
set -Eeuo pipefail

[[ "${AZCOPY_LOG_LOCATION:-}" == "$TEST_STATE/azcopy/logs" ]] || {
    echo "AzCopy log location was not exported" >&2
    exit 1
}
[[ "${AZCOPY_JOB_PLAN_LOCATION:-}" == "$TEST_STATE/azcopy/plans" ]] || {
    echo "AzCopy job-plan location was not exported" >&2
    exit 1
}
[[ -d "$AZCOPY_LOG_LOCATION" && -d "$AZCOPY_JOB_PLAN_LOCATION" ]] || {
    echo "AzCopy work directories were not created" >&2
    exit 1
}

key_from_url() {
    local url="${1%%\?*}"
    printf '%s\n' "${url#https://account.blob.core.windows.net/backups/backmaster/}"
}

command="$1"
shift
case "$command" in
    copy)
        source="$1"
        destination="$2"
        if [[ "$source" == https://* ]]; then
            key="$(key_from_url "$source")"
            cp "$TEST_REMOTE/$key" "$destination"
            printf 'GET %s\n' "$source" >>"$TEST_LOG"
        else
            key="$(key_from_url "$destination")"
            mkdir -p "$(dirname "$TEST_REMOTE/$key")"
            cp "$source" "$TEST_REMOTE/$key"
            printf 'PUT %s\n' "$destination" >>"$TEST_LOG"
        fi
        ;;
    list)
        key="$(key_from_url "$1")"
        root="$TEST_REMOTE/$key"
        [[ -d "$root" ]] || exit 0
        find "$root" -type f -printf '%P; Content Length: %s\n' | sort
        ;;
    remove)
        key="$(key_from_url "$1")"
        printf 'REMOVE %s %s\n' "$1" "$*" >>"$TEST_LOG"
        if [[ "$key" == basebackups/* ]]; then
            rm -rf -- "$TEST_REMOTE/$key"
        fi
        ;;
    *) exit 64 ;;
esac
AZCOPY
chmod +x "$temporary/bin/azcopy"

run_exporter() {
    HOME=/var/lib/postgresql BACKMASTER_STATE_DIRECTORY="$temporary/state" \
        PATH="$temporary/bin:$PATH" TEST_REMOTE="$temporary/remote" \
        TEST_LOG="$temporary/log" TEST_STATE="$temporary/state" \
        EXPORTER_CONFIG="$temporary/config.env" \
        "$ROOT/exporters/azcopy/exporter" "$@"
}

run_exporter connectivitycheck
[[ -d "$temporary/state/azcopy/logs" && \
    -d "$temporary/state/azcopy/plans" ]] || {
    echo "AzCopy work directories were not created in instance state" >&2
    exit 1
}
run_exporter publish "$temporary/stage" >/dev/null
last_put="$(grep '^PUT ' "$temporary/log" | tail -1)"
[[ "$last_put" == *'/basebackups/2026-08-02-006-axon/manifest.json?sig=test' ]] || {
    echo "manifest was not uploaded last or SAS placement is invalid" >&2
    exit 1
}
grep '/payload/space%20name?sig=test' "$temporary/log" >/dev/null || {
    echo "payload path was not URL encoded" >&2
    exit 1
}
[[ "$(run_exporter latest-epoch)" == 1785683663 ]] || {
    echo "latest epoch mismatch" >&2
    exit 1
}
[[ "$(run_exporter next-serial 2026-08-02)" == 7 ]] || {
    echo "serial mismatch" >&2
    exit 1
}

printf 'wal\n' >"$temporary/wal"
run_exporter put-file "$temporary/wal" wal/00000001 >/dev/null
run_exporter get-file wal/00000001 "$temporary/restored-wal" >/dev/null
cmp "$temporary/wal" "$temporary/restored-wal"

run_exporter retain >/dev/null
[[ -d "$temporary/remote/basebackups/2026-08-02-005-myelin" ]]
[[ ! -e "$temporary/remote/basebackups/2026-07-20-004-axon" ]]
grep 'REMOVE .*objects/wal.*--include-before=' "$temporary/log" >/dev/null || {
    echo "WAL retention was not applied" >&2
    exit 1
}

sed -i 's/^RETENTION_DAYS=1$/RETENTION_DAYS=none/' \
    "$temporary/config.env"
sed -i 's/^WAL_RETENTION_DAYS=15$/WAL_RETENTION_DAYS=unlimited/' \
    "$temporary/config.env"
: >"$temporary/log"
run_exporter retain >/dev/null
[[ ! -s "$temporary/log" ]] || {
    echo "unlimited retention still removed Azure data" >&2
    exit 1
}

sed -i 's/^RETENTION_DAYS=none$/RETENTION_DAYS=invalid/' \
    "$temporary/config.env"
if run_exporter retain >/dev/null 2>&1; then
    echo "invalid retention was accepted" >&2
    exit 1
fi

echo "AzCopy exporter tests passed"
