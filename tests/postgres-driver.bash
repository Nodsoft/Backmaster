#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT
temporary="$(mktemp -d)"
readonly temporary
trap 'rm -rf -- "$temporary"' EXIT
mkdir -p "$temporary/bin"

cat >"$temporary/bin/pg_isready" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat >"$temporary/bin/psql" <<'EOF'
#!/usr/bin/env bash
printf 'app\npostgres\nscratch\n'
EOF

cat >"$temporary/bin/pg_dump" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
database= output=
for argument in "$@"; do
    case "$argument" in
        --dbname=*) database="${argument#*=}" ;;
        --file=*) output="${argument#*=}" ;;
    esac
done
[[ -n "$database" && -n "$output" ]]
printf 'dump of %s\n' "$database" >"$output"
printf '%s\n' "$database" >>"$TEST_DUMP_LOG"
EOF

cat >"$temporary/bin/pg_dumpall" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '-- globals'
EOF

cat >"$temporary/bin/pg_basebackup" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
destination=
for argument in "$@"; do
    case "$argument" in --pgdata=*) destination="${argument#*=}" ;; esac
done
[[ -n "$destination" ]]
printf 'base backup\n' >"$destination/base.tar.gz"
printf '%s\n' "$*" >"$TEST_BASEBACKUP_LOG"
EOF
chmod +x "$temporary/bin/"*

cat >"$temporary/logical.env" <<'EOF'
PGHOST=/var/run/postgresql
PGPORT=5431
PGUSER=postgres
PG_BACKUP_MODE=logical
PGDATABASE=postgres
PG_LOGICAL_COMPRESSION=6
PG_LOGICAL_GLOBALS_GZIP_LEVEL=6
PG_DATABASE_INCLUDE=$'app\npostgres\nscratch'
PG_DATABASE_EXCLUDE=scratch
EOF

logical_payload="$temporary/logical"
mkdir "$logical_payload"
PATH="$temporary/bin:$PATH" DRIVER_CONFIG="$temporary/logical.env" \
    BACKUP_NAME=test-logical TEST_DUMP_LOG="$temporary/dumps" \
    "$ROOT/drivers/postgres/driver" prepare "$logical_payload"

[[ "$(<"$temporary/dumps")" == $'app\npostgres' ]]
[[ "$(jq -r '.format' "$logical_payload/databases.json")" == \
    backmaster-postgres-logical-v1 ]]
[[ "$(jq -r '.databases[].database' "$logical_payload/databases.json")" == \
    $'app\npostgres' ]]
while IFS= read -r dump_file; do
    [[ -s "$logical_payload/$dump_file" ]]
done < <(jq -r '.databases[].file' "$logical_payload/databases.json")
[[ "$(gzip -dc "$logical_payload/globals.sql.gz")" == '-- globals' ]]

cat >"$temporary/missing.env" <<'EOF'
PGHOST=/var/run/postgresql
PGPORT=5431
PGUSER=postgres
PG_BACKUP_MODE=logical
PG_DATABASE_INCLUDE=missing
EOF
mkdir "$temporary/missing"
if PATH="$temporary/bin:$PATH" DRIVER_CONFIG="$temporary/missing.env" \
    BACKUP_NAME=test-missing TEST_DUMP_LOG="$temporary/missing-dumps" \
    "$ROOT/drivers/postgres/driver" prepare "$temporary/missing" 2>/dev/null; then
    echo "missing included database unexpectedly succeeded" >&2
    exit 1
fi

cat >"$temporary/physical.env" <<'EOF'
PGHOST=/var/run/postgresql
PGPORT=5431
PGUSER=postgres
EOF
mkdir "$temporary/physical"
PATH="$temporary/bin:$PATH" DRIVER_CONFIG="$temporary/physical.env" \
    BACKUP_NAME=test-physical TEST_BASEBACKUP_LOG="$temporary/basebackup" \
    "$ROOT/drivers/postgres/driver" prepare "$temporary/physical"
[[ -s "$temporary/physical/base.tar.gz" ]]
grep -- '--wal-method=stream' "$temporary/basebackup" >/dev/null

echo "PostgreSQL driver tests passed"
