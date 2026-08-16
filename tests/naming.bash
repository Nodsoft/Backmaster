#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/config/instances.d" "$TMP/install/drivers/fake" \
    "$TMP/install/exporters/fake" "$TMP/bin" "$TMP/staging"

cat >"$TMP/install/drivers/fake/driver" <<'DRIVER'
#!/usr/bin/env bash
case "$1" in
    prepare) printf 'payload\n' >"$2/data" ;;
    *) exit 64 ;;
esac
DRIVER
chmod +x "$TMP/install/drivers/fake/driver"

cat >"$TMP/install/exporters/fake/exporter" <<'EXPORTER'
#!/usr/bin/env bash
case "$1" in
    latest-epoch) exit 3 ;;
    next-serial) printf '7\n' ;;
    publish) jq -r .backup_name "$2/manifest.json" >"$TEST_OUTPUT" ;;
    retain) ;;
    *) exit 64 ;;
esac
EXPORTER
chmod +x "$TMP/install/exporters/fake/exporter"

cat >"$TMP/bin/date" <<'DATE'
#!/usr/bin/env bash
case "$*" in
    "--utc +%Y-%m-%dT%H%M%SZ") printf '2026-08-02T151423Z\n' ;;
    "+%s") printf '1785683663\n' ;;
    "--iso-8601=seconds") printf '2026-08-02T15:14:23+00:00\n' ;;
    *) exec /usr/bin/date "$@" ;;
esac
DATE
cat >"$TMP/bin/hostname" <<'HOSTNAME'
#!/usr/bin/env bash
printf 'axon\n'
HOSTNAME
cat >"$TMP/bin/consul" <<'CONSUL'
#!/usr/bin/env bash
while (($#)); do
    case "$1" in
        -*) shift ;;
        service/*) shift; exec "$@" ;;
        *) shift ;;
    esac
done
CONSUL
chmod +x "$TMP/bin/"*

run_case() {
    local mode="$1"
    local suffix_mode="$2"
    local suffix_value="$3"
    local expected="$4"

    cat >"$TMP/config/instances.d/test.env" <<EOF
INSTANCE_NAME=test
NODE_NAME=test-node
DRIVER=fake
EXPORTER=fake
STAGING_ROOT=$TMP/staging
MAX_AGE_SECONDS=1
BACKUP_NAME_MODE=$mode
BACKUP_NAME_SUFFIX_MODE=$suffix_mode
BACKUP_NAME_SUFFIX_VALUE=$suffix_value
EOF
    TEST_OUTPUT="$TMP/output" PATH="$TMP/bin:$PATH" \
        BACKMASTER_CONFIG_ROOT="$TMP/config" \
        BACKMASTER_INSTALL_ROOT="$TMP/install" \
        "$ROOT/bin/backmaster" run test --force >/dev/null
    [[ "$(<"$TMP/output")" == "$expected" ]] || {
        printf 'expected %s, got %s\n' "$expected" "$(<"$TMP/output")" >&2
        exit 1
    }
}

run_case daily none "" 2026-08-02
run_case daily-serial hostname "" 2026-08-02-007-axon
run_case daily-time custom primary 2026-08-02T151423Z-primary
