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
printf 'one staged artifact\n' >"$2/archive.gz"
DRIVER

cat >"$TMP/install/exporters/fake/exporter" <<'EXPORTER'
#!/usr/bin/env bash
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
    TEST_COUNT="$TMP/count" TEST_RETAINED="$TMP/retained" PATH="$TMP/bin:$PATH" \
        BACKMASTER_CONFIG_ROOT="$TMP/config" BACKMASTER_INSTALL_ROOT="$TMP/install" \
        "$ROOT/bin/backmaster" run test --force >/dev/null
}

if run; then echo "first export unexpectedly succeeded" >&2; exit 1; fi
ready="$(find "$TMP/staging/test" -maxdepth 1 -name '*.ready' -type d -print -quit)"
[[ -n "$ready" ]] || { echo "failed export did not preserve ready stage" >&2; exit 1; }
run
[[ ! -e "$ready" && -s "$TMP/retained" ]] || { echo "resume did not publish and clean stage" >&2; exit 1; }
