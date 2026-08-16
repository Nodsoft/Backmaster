#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT
temporary="$(mktemp -d)"
readonly temporary
trap 'rm -rf -- "$temporary"' EXIT

mkdir -p "$temporary/config/instances.d" "$temporary/install/drivers/fake" \
    "$temporary/install/exporters/fake" "$temporary/bin" "$temporary/staging"

cat >"$temporary/install/drivers/fake/driver" <<'DRIVER'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$1" == prepare && -d "$2" ]] || exit 64
mkdir -p "$2/nested"
printf 'database payload\n' >"$2/nested/example.sql"
printf 'metadata\n' >"$2/databases.json"
DRIVER

cat >"$temporary/install/exporters/fake/exporter" <<'EXPORTER'
#!/usr/bin/env bash
set -Eeuo pipefail
case "$1" in
    latest-epoch) exit 3 ;;
    retain) ;;
    publish)
        stage="$2"
        cp -a -- "$stage" "$TEST_CAPTURE"
        ;;
    *) exit 64 ;;
esac
EXPORTER

cat >"$temporary/bin/date" <<'DATE'
#!/usr/bin/env bash
case "$*" in
    "--utc +%Y-%m-%dT%H%M%SZ") printf '2026-08-06T120000Z\n' ;;
    "+%s") printf '1786017600\n' ;;
    "--iso-8601=seconds") printf '2026-08-06T12:00:00+00:00\n' ;;
    *) exec /usr/bin/date "$@" ;;
esac
DATE

cat >"$temporary/bin/consul" <<'CONSUL'
#!/usr/bin/env bash
while (($#)); do
    case "$1" in
        -*) shift ;;
        service/*) shift; exec "$@" ;;
        *) shift ;;
    esac
done
CONSUL
chmod +x "$temporary/install/drivers/fake/driver" \
    "$temporary/install/exporters/fake/exporter" "$temporary/bin/"*

run_format() {
    local format="$1" level="$2" capture="$temporary/capture-$1" extract
    local archive_file archive_sha256
    rm -rf -- "$capture"
    cat >"$temporary/config/instances.d/archive.env" <<EOF
INSTANCE_NAME=archive
NODE_NAME=test
DRIVER=fake
EXPORTER=fake
STAGING_ROOT=$temporary/staging
BACKUP_NAME_MODE=daily-time
BACKUP_NAME_SUFFIX_MODE=none
BACKUP_ARCHIVE_FORMAT=$format
BACKUP_ARCHIVE_COMPRESSION_LEVEL=$level
EOF
    PATH="$temporary/bin:$PATH" TEST_CAPTURE="$capture" \
        BACKMASTER_CONFIG_ROOT="$temporary/config" \
        BACKMASTER_INSTALL_ROOT="$temporary/install" \
        "$ROOT/bin/backmaster" run archive --force >/dev/null

    [[ "$(jq -r '.artifact.layout' "$capture/manifest.json")" == archive ]]
    [[ "$(jq -r '.artifact.format' "$capture/manifest.json")" == "$format" ]]
    [[ "$(jq -r '.artifact.compression_level' "$capture/manifest.json")" == "$level" ]]
    archive_file="$(jq -r '.artifact.file' "$capture/manifest.json")"
    archive_sha256="$(sha256sum "$capture/$archive_file")"
    [[ "${archive_sha256%% *}" == "$(jq -r '.artifact.sha256' "$capture/manifest.json")" ]]
    [[ "$(find "$capture" -mindepth 1 -maxdepth 1 -type f | wc -l)" -eq 2 ]]
    [[ ! -e "$capture/payload" && ! -e "$capture/checksums.sha256" ]]

    extract="$temporary/extract-$format"
    mkdir -p "$extract"
    case "$format" in
        zip) unzip -q "$capture/backup.zip" -d "$extract" ;;
        tar.gz) tar -xzf "$capture/backup.tar.gz" -C "$extract" ;;
        tar.xz) tar -xJf "$capture/backup.tar.xz" -C "$extract" ;;
        tar.zst) tar --zstd -xf "$capture/backup.tar.zst" -C "$extract" ;;
    esac
    (cd "$extract" && sha256sum --check checksums.sha256 >/dev/null)
    [[ "$(<"$extract/payload/nested/example.sql")" == "database payload" ]]
}

run_format zip 9
run_format tar.gz 1
run_format tar.xz 0
run_format tar.zst 19

sed -i 's/BACKUP_ARCHIVE_FORMAT=tar.zst/BACKUP_ARCHIVE_FORMAT=tar.br/' \
    "$temporary/config/instances.d/archive.env"
if PATH="$temporary/bin:$PATH" TEST_CAPTURE="$temporary/invalid" \
    BACKMASTER_CONFIG_ROOT="$temporary/config" \
    BACKMASTER_INSTALL_ROOT="$temporary/install" \
    "$ROOT/bin/backmaster" run archive --force >/dev/null 2>&1; then
    echo "invalid archive format was accepted" >&2
    exit 1
fi

echo "archive format tests passed"
