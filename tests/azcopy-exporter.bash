#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT
temporary="$(mktemp -d)"
readonly temporary
trap 'rm -rf -- "$temporary"' EXIT
mkdir -p "$temporary/bin" "$temporary/remote/basebackups" \
    "$temporary/stage/payload/databases"

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
printf 'database one\n' >"$temporary/stage/payload/databases/one.dump"
printf 'database two\n' >"$temporary/stage/payload/databases/two.dump"
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
# Real AzCopy may read stdin. Deliberately drain it so the test catches callers
# that let an AzCopy child consume a surrounding file-enumeration stream.
cat >/dev/null
case "$command" in
    copy)
        source="$1"
        destination="$2"
        if [[ "$source" == https://* ]]; then
            key="$(key_from_url "$source")"
            printf 'GET %s\n' "$source" >>"$TEST_LOG"
            if [[ -n "${TEST_UNREADABLE:-}" && "$key" == $TEST_UNREADABLE ]]; then
                echo 'BlobArchived (simulated)' >&2
                exit 1
            fi
            [[ -z "${TEST_MISSING_DOWNLOAD:-}" || "$key" != "$TEST_MISSING_DOWNLOAD" ]] || exit 0
            cp "$TEST_REMOTE/$key" "$destination"
        else
            key="$(key_from_url "$destination")"
            if [[ -n "${TEST_UPLOAD_FAILURE:-}" && "$key" == $TEST_UPLOAD_FAILURE ]]; then
                echo 'upload failure (simulated)' >&2
                exit 1
            fi
            if [[ "$key" == catalogue/* ]]; then
                [[ "$*" == *--block-blob-tier=Hot* ]] || exit 1
            fi
            mkdir -p "$(dirname "$TEST_REMOTE/$key")"
            cp "$source" "$TEST_REMOTE/$key"
            printf 'PUT %s\n' "$destination" >>"$TEST_LOG"
        fi
        ;;
    list)
        key="$(key_from_url "$1")"
        root="$TEST_REMOTE/$key"
        if [[ -n "${TEST_LIST_FAILURE:-}" && "$key" == "$TEST_LIST_FAILURE" ]]; then
            # Include a valid-looking partial result: callers must discard it.
            printf '1785683663/2026-08-02-006-axon.json; Content Length: 100\n'
            echo 'listing failure (simulated)' >&2
            exit 1
        fi
        [[ -d "$root" ]] || exit 0
        find "$root" -type f -printf '%P; Content Length: %s\n' | sort
        ;;
    remove)
        key="$(key_from_url "$1")"
        printf 'REMOVE %s %s\n' "$1" "$*" >>"$TEST_LOG"
        if [[ -n "${TEST_REMOVE_FAILURE:-}" && "$key" == $TEST_REMOVE_FAILURE ]]; then
            echo 'removal failure (simulated)' >&2
            exit 1
        fi
        if [[ "$key" == basebackups/* || "$key" == catalogue/* ]]; then
            rm -rf -- "$TEST_REMOTE/$key"
        fi
        ;;
    *) exit 64 ;;
esac
AZCOPY
chmod +x "$temporary/bin/azcopy"

run_exporter() {
    HOME=/var/lib/postgresql BACKMASTER_STATE_DIRECTORY="$temporary/state" \
        PATH="$temporary/bin:$PATH" TEST_REMOTE="${TEST_REMOTE_OVERRIDE:-$temporary/remote}" \
        TEST_LOG="$temporary/log" TEST_STATE="$temporary/state" \
        EXPORTER_CONFIG="$temporary/config.env" \
        "$ROOT/exporters/azcopy/exporter" "$@"
}

expect_failure() {
    local expected_status="$1" message="$2" status
    shift 2
    if "$@" >"$temporary/output" 2>"$temporary/error"; then
        echo "unexpected success: $*" >&2
        exit 1
    else
        status=$?
    fi
    [[ "$status" == "$expected_status" ]] || {
        printf 'expected status %s, got %s: %s\n' "$expected_status" "$status" "$*" >&2
        cat "$temporary/error" >&2
        exit 1
    }
    [[ -z "$message" ]] || grep -Fq -- "$message" "$temporary/error" "$temporary/output" || {
        printf 'missing error %s: %s\n' "$message" "$*" >&2
        cat "$temporary/error" "$temporary/output" >&2
        exit 1
    }
}

run_exporter connectivitycheck
[[ -d "$temporary/state/azcopy/logs" && \
    -d "$temporary/state/azcopy/plans" ]] || {
    echo "AzCopy work directories were not created in instance state" >&2
    exit 1
}
# Import the two original fixtures so the existing retention assertions cover
# indexed backups. Import never needs any other historical manifest.
run_exporter catalogue-import 2026-08-02-005-myelin >/dev/null
run_exporter catalogue-import 2026-07-20-004-axon >/dev/null
run_exporter publish "$temporary/stage" >/dev/null
backup="$temporary/remote/basebackups/2026-08-02-006-axon"
[[ -f "$backup/payload/databases/one.dump" && \
    -f "$backup/payload/databases/two.dump" ]] || {
    echo "nested database dumps were not uploaded" >&2
    exit 1
}
[[ "$(find "$backup" -type f | wc -l)" -eq 6 ]] || {
    echo "AzCopy did not upload every staged file" >&2
    exit 1
}
last_put="$(grep '^PUT ' "$temporary/log" | tail -1)"
[[ "$last_put" == *'/catalogue/1785683663/2026-08-02-006-axon.json?sig=test' ]] || {
    echo "catalogue was not uploaded last or SAS placement is invalid" >&2
    exit 1
}
[[ "$(grep '^PUT ' "$temporary/log" | tail -2 | head -1)" == \
    *'/basebackups/2026-08-02-006-axon/manifest.json?sig=test' ]]
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

mkdir -p "$temporary/archive-stage"
printf 'bundled backup\n' >"$temporary/archive-stage/backup.tar.zst"
archive_sha="$(sha256sum "$temporary/archive-stage/backup.tar.zst")"
jq -n --arg sha "${archive_sha%% *}" \
    '{schema:2,backup_name:"2026-08-03-001-axon",created_epoch:1784000000,
      artifact:{layout:"archive",format:"tar.zst",file:"backup.tar.zst",compression_level:3,sha256:$sha}}' \
    >"$temporary/archive-stage/manifest.json"
run_exporter publish "$temporary/archive-stage" >/dev/null
[[ -f "$temporary/remote/basebackups/2026-08-03-001-axon/backup.tar.zst" ]]
printf 'corrupt\n' >>"$temporary/archive-stage/backup.tar.zst"
if run_exporter publish "$temporary/archive-stage" >/dev/null 2>&1; then
    echo "AzCopy accepted an archive checksum mismatch" >&2
    exit 1
fi

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

# Regression fixtures are independent of the original retention fixtures.
sed -i 's/^RETENTION_DAYS=invalid$/RETENTION_DAYS=1/' "$temporary/config.env"
export TEST_REMOTE_OVERRIDE="$temporary/regression"
mkdir -p "$TEST_REMOTE_OVERRIDE/basebackups/2026-08-06-axon" \
    "$TEST_REMOTE_OVERRIDE/basebackups/2026-09-21-009-myelin"
old_name=2026-08-06-axon
new_name=2026-09-21-009-myelin
new_epoch="$(date +%s)"
printf '{"backup_name":"%s","created_epoch":1}\n' "$old_name" \
    >"$TEST_REMOTE_OVERRIDE/basebackups/$old_name/manifest.json"
jq -n --arg name "$new_name" --argjson epoch "$new_epoch" \
    '{schema:2,backup_name:$name,created_epoch:$epoch}' \
    >"$TEST_REMOTE_OVERRIDE/basebackups/$new_name/manifest.json"
export TEST_UNREADABLE="basebackups/$old_name/*"
: >"$temporary/log"
expect_failure 1 'legacy backups need catalogue migration' run_exporter latest-epoch
[[ ! -s "$temporary/log" ]] # No legacy manifest was downloaded.
[[ "$(run_exporter next-serial 2026-09-21)" == 10 ]]
[[ ! -s "$temporary/log" ]] # Serial discovery only lists names, including legacy.
run_exporter catalogue-import "$new_name" >/dev/null
[[ "$(grep -c '^GET ' "$temporary/log")" == 1 ]]
if grep -Fq "$old_name" "$temporary/log"; then
    echo "import downloaded an unrelated old manifest" >&2; exit 1
fi

# Even if all per-backup manifests are archived, only the newest catalogue
# record is downloaded by freshness and health checks.
export TEST_UNREADABLE='basebackups/*'
# A payload file named manifest.json is not itself a committed backup.
mkdir -p "$TEST_REMOTE_OVERRIDE/basebackups/$new_name/payload/nested"
printf '{}\n' >"$TEST_REMOTE_OVERRIDE/basebackups/$new_name/payload/nested/manifest.json"
: >"$temporary/log"
[[ "$(run_exporter latest-epoch)" == "$new_epoch" ]]
[[ "$(grep -c '^GET ' "$temporary/log")" == 1 ]]
grep -Fq "/catalogue/$new_epoch/$new_name.json?" "$temporary/log"
run_exporter healthcheck | grep -q '^OK:'
[[ "$(run_exporter next-serial 2026-09-21)" == 10 ]]
: >"$temporary/log"
run_exporter retain >"$temporary/output" 2>"$temporary/error"
grep -q 'preserving 1 unindexed backup' "$temporary/error"
[[ -f "$TEST_REMOTE_OVERRIDE/basebackups/$old_name/manifest.json" ]]
[[ ! -s "$temporary/log" ]] # No old download, and the sole indexed backup is kept.

# List errors cannot turn into "empty", partial success, serial reuse, or deletes.
for prefix in catalogue basebackups; do
    if [[ "$prefix" == catalogue ]]; then verb=latest-epoch; else verb=next-serial; fi
    TEST_LIST_FAILURE="$prefix" expect_failure 1 'remote listing failed' \
        run_exporter "$verb" 2026-09-21
    : >"$temporary/log"
    TEST_LIST_FAILURE="$prefix" expect_failure 1 'remote listing failed' run_exporter retain
    [[ ! -s "$temporary/log" ]]
done
TEST_LIST_FAILURE=catalogue expect_failure 2 'unable to determine latest' run_exporter healthcheck

# An unreadable/corrupt newest catalogue record is an error, never an older
# fallback or a false "no completed backup" result.
catalogue_key="catalogue/$new_epoch/$new_name.json"
TEST_UNREADABLE="$catalogue_key" expect_failure 1 'remote manifest download failed' \
    run_exporter latest-epoch
TEST_MISSING_DOWNLOAD="$catalogue_key" expect_failure 1 'download produced no file' \
    run_exporter latest-epoch
cp "$TEST_REMOTE_OVERRIDE/$catalogue_key" "$temporary/good-manifest"
printf 'broken JSON\n' >"$TEST_REMOTE_OVERRIDE/$catalogue_key"
expect_failure 1 'invalid manifest name or creation epoch' run_exporter latest-epoch
for bad_epoch in '"123"' -1 1.5 null; do
    jq --argjson epoch "$bad_epoch" '.created_epoch=$epoch' "$temporary/good-manifest" \
        >"$TEST_REMOTE_OVERRIDE/$catalogue_key"
    expect_failure 1 'invalid manifest name or creation epoch' run_exporter latest-epoch
done
jq '.created_epoch=2' "$temporary/good-manifest" >"$TEST_REMOTE_OVERRIDE/$catalogue_key"
expect_failure 1 'catalogue epoch mismatch' run_exporter latest-epoch
cp "$temporary/good-manifest" "$TEST_REMOTE_OVERRIDE/$catalogue_key"
mv "$TEST_REMOTE_OVERRIDE/basebackups/$new_name/manifest.json" "$temporary/missing-manifest"
expect_failure 1 'missing backup manifest' run_exporter latest-epoch
: >"$temporary/log"
expect_failure 1 'missing backup manifest' run_exporter retain
[[ ! -s "$temporary/log" ]] # Stale records cannot count toward redundancy.
mv "$temporary/missing-manifest" "$TEST_REMOTE_OVERRIDE/basebackups/$new_name/manifest.json"
mkdir -p "$TEST_REMOTE_OVERRIDE/catalogue/0"
cp "$temporary/good-manifest" "$TEST_REMOTE_OVERRIDE/catalogue/0/$new_name.json"
expect_failure 1 'conflicting catalogue records' run_exporter latest-epoch
expect_failure 1 'conflicting catalogue records' run_exporter retain
rm "$TEST_REMOTE_OVERRIDE/catalogue/0/$new_name.json"
expect_failure 1 'invalid backup name' run_exporter catalogue-import ../outside
expect_failure 1 'invalid backup name' run_exporter catalogue-import .

# Empty stores are distinct from failed listings and legacy-only stores.
mkdir -p "$temporary/empty"
TEST_REMOTE_OVERRIDE="$temporary/empty" expect_failure 3 '' run_exporter latest-epoch
TEST_REMOTE_OVERRIDE="$temporary/empty" TEST_LIST_FAILURE=basebackups \
    expect_failure 1 'remote listing failed' run_exporter latest-epoch

# Publication failure must leave the previous latest untouched. The same sealed
# stage can then retry after its base manifest exists but catalogue record does not.
mkdir -p "$temporary/retry-stage/payload"
printf 'backup\n' >"$temporary/retry-stage/payload/dump"
printf 'checksums\n' >"$temporary/retry-stage/checksums.sha256"
retry_epoch=$((new_epoch + 1))
jq -n --argjson epoch "$retry_epoch" \
    '{schema:2,backup_name:"retry-backup",created_epoch:$epoch}' \
    >"$temporary/retry-stage/manifest.json"
TEST_UPLOAD_FAILURE='basebackups/retry-backup/payload/*' \
    expect_failure 1 'backup upload failed' run_exporter publish "$temporary/retry-stage"
[[ ! -e "$TEST_REMOTE_OVERRIDE/basebackups/retry-backup/manifest.json" ]]
TEST_UPLOAD_FAILURE='basebackups/retry-backup/manifest.json' \
    expect_failure 1 'backup manifest upload failed' run_exporter publish "$temporary/retry-stage"
[[ ! -e "$TEST_REMOTE_OVERRIDE/catalogue/$retry_epoch/retry-backup.json" ]]
TEST_UPLOAD_FAILURE='catalogue/*' expect_failure 1 'catalogue publication failed' \
    run_exporter publish "$temporary/retry-stage"
[[ "$(run_exporter latest-epoch)" == "$new_epoch" ]]
[[ -s "$TEST_REMOTE_OVERRIDE/basebackups/retry-backup/manifest.json" ]]
export TEST_UNREADABLE="basebackups/$old_name/*"
run_exporter publish "$temporary/retry-stage" >/dev/null
run_exporter publish "$temporary/retry-stage" >/dev/null # Idempotent retry.
[[ "$(run_exporter latest-epoch)" == "$retry_epoch" ]]
jq '.created_epoch+=1' "$temporary/retry-stage/manifest.json" >"$temporary/changed-manifest"
cp "$temporary/changed-manifest" "$temporary/retry-stage/manifest.json"
expect_failure 1 'backup name already committed' run_exporter publish "$temporary/retry-stage"

# Imported old records need no body reads for retention; unindexed backups remain
# untouched. Keep the two newest indexed backups regardless of lexicographic name.
unset TEST_UNREADABLE
run_exporter catalogue-import "$old_name" >/dev/null
export TEST_UNREADABLE='basebackups/*'
: >"$temporary/log"
TEST_REMOVE_FAILURE='catalogue/1/*' expect_failure 1 'catalogue removal failed' run_exporter retain
[[ -s "$TEST_REMOTE_OVERRIDE/basebackups/$old_name/manifest.json" ]]
[[ -s "$TEST_REMOTE_OVERRIDE/catalogue/1/$old_name.json" ]]
run_exporter retain >/dev/null
[[ ! -e "$TEST_REMOTE_OVERRIDE/basebackups/$old_name" ]]
[[ ! -e "$TEST_REMOTE_OVERRIDE/catalogue/1/$old_name.json" ]]
[[ -s "$TEST_REMOTE_OVERRIDE/$catalogue_key" ]]
if grep -q '^GET ' "$temporary/log"; then
    echo "retention downloaded a historical manifest" >&2; exit 1
fi

# Exercise the actual core: catalogue failure preserves .ready; the next run
# retries publication without preparing again, and a third run skips as fresh.
mkdir -p "$temporary/core/config/instances.d" "$temporary/core/install/drivers/fake" \
    "$temporary/core/install/exporters/azcopy" "$temporary/core/remote/basebackups/old-archive"
ln -s "$ROOT/exporters/azcopy/exporter" "$temporary/core/install/exporters/azcopy/exporter"
cat >"$temporary/core/install/drivers/fake/driver" <<'DRIVER'
#!/usr/bin/env bash
set -eu
[[ "$1" == prepare ]] || exit 64
printf 'prepared\n' >>"$TEST_DRIVER_CALLS"
printf 'dump\n' >"$2/dump"
DRIVER
cat >"$temporary/bin/consul" <<'CONSUL'
#!/usr/bin/env bash
while (($#)); do
    case "$1" in
        service/*) shift; exec "$@" ;;
        *) shift ;;
    esac
done
exit 64
CONSUL
chmod +x "$temporary/bin/consul" "$temporary/core/install/drivers/fake/driver"
cat >"$temporary/core/config/instances.d/test.env" <<CONFIG
INSTANCE_NAME=test
NODE_NAME=axon
DRIVER=fake
EXPORTER=azcopy
EXPORTER_CONFIG=$temporary/config.env
STAGING_ROOT=$temporary/core/staging
BACKUP_NAME_MODE=daily-serial
BACKUP_NAME_SUFFIX_MODE=none
CONFIG
printf '{"backup_name":"old-archive","created_epoch":1}\n' \
    >"$temporary/core/remote/basebackups/old-archive/manifest.json"
run_core() {
    TEST_REMOTE="$temporary/core/remote" TEST_LOG="$temporary/log" \
        TEST_STATE="$temporary/core/staging/test" TEST_DRIVER_CALLS="$temporary/core/driver-calls" \
        PATH="$temporary/bin:$PATH" BACKMASTER_CONFIG_ROOT="$temporary/core/config" \
        BACKMASTER_INSTALL_ROOT="$temporary/core/install" "$ROOT/bin/backmaster" run test "$@"
}
export TEST_UNREADABLE=basebackups/old-archive/manifest.json
TEST_UPLOAD_FAILURE='catalogue/*' expect_failure 1 'catalogue publication failed' run_core --force
ready="$(find "$temporary/core/staging/test" -maxdepth 1 -name '*.ready' -type d -print -quit)"
[[ -n "$ready" && -s "$ready/manifest.json" && -s "$ready/payload/dump" ]]
run_core "" >/dev/null
[[ ! -e "$ready" && "$(wc -l <"$temporary/core/driver-calls")" == 1 ]]
run_core "" | grep -q 'result=skipped reason=fresh_backup_exists'
[[ "$(wc -l <"$temporary/core/driver-calls")" == 1 ]]

echo "AzCopy exporter tests passed"
