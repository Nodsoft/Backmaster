#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/config/instances.d" "$TMP/install/drivers/fake" \
    "$TMP/install/exporters/fake" "$TMP/bin" "$TMP/staging"

cat >"$TMP/install/drivers/fake/driver" <<'DRIVER'
#!/usr/bin/env bash
[[ "$1" == prepare ]] || exit 64
[[ -z "${TEST_DRIVER_CALLED:-}" ]] || printf 'called\n' >"$TEST_DRIVER_CALLED"
printf 'one staged artifact\n' >"$2/archive.gz"
DRIVER

cat >"$TMP/install/exporters/fake/exporter" <<'EXPORTER'
#!/usr/bin/env bash
[[ -z "${TEST_EXPECTED_STATE:-}" || \
    "${BACKMASTER_STATE_DIRECTORY:-}" == "$TEST_EXPECTED_STATE" ]] || {
    echo "instance state directory was not exported" >&2
    exit 1
}
case "$1" in
    latest-epoch) exit 3 ;;
    publish)
        count=0; [[ -r "$TEST_COUNT" ]] && count="$(<"$TEST_COUNT")"
        count=$((count + 1)); printf '%s\n' "$count" >"$TEST_COUNT"
        (( count > 1 )) || exit 1
        [[ -s "$2/payload/archive.gz" && -s "$2/checksums.sha256" && -s "$2/manifest.json" ]]
        ;;
    retain) printf 'retained\n' >"$TEST_RETAINED" ;;
    *) exit 64 ;;
esac
EXPORTER
chmod +x "$TMP/install/drivers/fake/driver" "$TMP/install/exporters/fake/exporter"

cat >"$TMP/bin/date" <<'DATE'
#!/usr/bin/env bash
case "$*" in
    "--utc +%Y-%m-%dT%H%M%SZ") printf '2026-08-02T151423Z\n' ;;
    "+%s") printf '1785683663\n' ;;
    "--iso-8601=seconds") printf '2026-08-02T15:14:23+00:00\n' ;;
    *) exec /usr/bin/date "$@" ;;
esac
DATE
cat >"$TMP/bin/consul" <<'CONSUL'
#!/usr/bin/env bash
while (($#)); do case "$1" in -*) shift;; service/*) shift; exec "$@";; *) shift;; esac; done
CONSUL
cat >"$TMP/bin/mkdir" <<'MKDIR'
#!/usr/bin/env bash
if [[ -n "${TEST_DENIED_PARENT:-}" ]]; then
    for argument in "$@"; do
        if [[ "$argument" == "$TEST_DENIED_PARENT" || "$argument" == /payload ]]; then
            printf "mkdir: cannot create directory '%s': Permission denied\n" "$argument" >&2
            exit 1
        fi
    done
fi
exec /usr/bin/mkdir "$@"
MKDIR
chmod +x "$TMP/bin/"*

cat >"$TMP/config/instances.d/test.env" <<EOF
INSTANCE_NAME=test
NODE_NAME=axon
DRIVER=fake
EXPORTER=fake
STAGING_ROOT=$TMP/staging
BACKUP_NAME_MODE=daily-time
BACKUP_NAME_SUFFIX_MODE=none
EOF

run() {
    TEST_COUNT="$TMP/count" TEST_RETAINED="$TMP/retained" \
        TEST_EXPECTED_STATE="$TMP/staging/test" PATH="$TMP/bin:$PATH" \
        BACKMASTER_CONFIG_ROOT="$TMP/config" BACKMASTER_INSTALL_ROOT="$TMP/install" \
        "$ROOT/bin/backmaster" run test --force >/dev/null
}

if run; then echo "first export unexpectedly succeeded" >&2; exit 1; fi
ready="$(find "$TMP/staging/test" -maxdepth 1 -name '*.ready' -type d -print -quit)"
[[ -n "$ready" ]] || { echo "failed export did not preserve ready stage" >&2; exit 1; }
run
[[ ! -e "$ready" && -s "$TMP/retained" ]] || { echo "resume did not publish and clean stage" >&2; exit 1; }

denied_parent="$TMP/denied/test"
driver_called="$TMP/driver-called"
sed -i "s|^STAGING_ROOT=.*|STAGING_ROOT=$TMP/denied|" \
    "$TMP/config/instances.d/test.env"
set +e
denied_output="$(
    TEST_COUNT="$TMP/count" TEST_RETAINED="$TMP/retained" \
        TEST_DENIED_PARENT="$denied_parent" TEST_DRIVER_CALLED="$driver_called" \
        TEST_EXPECTED_STATE="$TMP/denied/test" \
        PATH="$TMP/bin:$PATH" BACKMASTER_CONFIG_ROOT="$TMP/config" \
        BACKMASTER_INSTALL_ROOT="$TMP/install" \
        "$ROOT/bin/backmaster" run test --force 2>&1
)"
denied_status=$?
set -e
[[ "$denied_status" -ne 0 ]] || { echo "unwritable staging root unexpectedly succeeded" >&2; exit 1; }
[[ "$denied_output" == *"staging_parent_create_failed path=$denied_parent"* ]] || {
    printf 'missing actionable staging error:\n%s\n' "$denied_output" >&2
    exit 1
}
[[ ! -e "$driver_called" ]] || { echo "driver ran after staging creation failed" >&2; exit 1; }
