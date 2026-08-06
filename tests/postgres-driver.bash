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
printf '%s\n' "${TEST_DATABASE_OUTPUT:-$'app\npostgres\nscratch'}"
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
printf '%s\n' "$*" >>"$TEST_DUMP_ARGUMENT_LOG"
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
    TEST_DUMP_ARGUMENT_LOG="$temporary/dump-arguments" \
    "$ROOT/drivers/postgres/driver" prepare "$logical_payload"

[[ "$(<"$temporary/dumps")" == $'app\npostgres' ]]
[[ "$(jq -r '.format' "$logical_payload/databases.json")" == \
    backmaster-postgres-logical-v1 ]]
[[ "$(jq -r '.dump_format' "$logical_payload/databases.json")" == custom ]]
[[ "$(jq -r '.file_naming' "$logical_payload/databases.json")" == sha256 ]]
[[ "$(jq -r '.databases[].database' "$logical_payload/databases.json")" == \
    $'app\npostgres' ]]
while IFS= read -r dump_file; do
    [[ -s "$logical_payload/$dump_file" ]]
done < <(jq -r '.databases[].file' "$logical_payload/databases.json")
grep -- '--format=custom' "$temporary/dump-arguments" >/dev/null
grep -- '--compress=6' "$temporary/dump-arguments" >/dev/null
[[ "$(gzip -dc "$logical_payload/globals.sql.gz")" == '-- globals' ]]

cat >"$temporary/plain.env" <<'EOF'
PGHOST=/var/run/postgresql
PGPORT=5431
PGUSER=postgres
PG_BACKUP_MODE=logical
PG_LOGICAL_FORMAT=plain
PG_LOGICAL_FILE_NAMING=plain
PG_DATABASE_INCLUDE=$'app\npostgres'
EOF
plain_payload="$temporary/plain"
mkdir "$plain_payload"
PATH="$temporary/bin:$PATH" DRIVER_CONFIG="$temporary/plain.env" \
    BACKUP_NAME=test-plain TEST_DUMP_LOG="$temporary/plain-dumps" \
    TEST_DUMP_ARGUMENT_LOG="$temporary/plain-dump-arguments" \
    "$ROOT/drivers/postgres/driver" prepare "$plain_payload"
[[ -s "$plain_payload/databases/app.sql" ]]
[[ -s "$plain_payload/databases/postgres.sql" ]]
[[ "$(jq -r '.dump_format' "$plain_payload/databases.json")" == plain ]]
[[ "$(jq -r '.file_naming' "$plain_payload/databases.json")" == plain ]]
[[ "$(jq -r '.databases[].file' "$plain_payload/databases.json")" == \
    $'databases/app.sql\ndatabases/postgres.sql' ]]
grep -- '--format=plain' "$temporary/plain-dump-arguments" >/dev/null
if grep -- '--compress=' "$temporary/plain-dump-arguments" >/dev/null; then
    echo "plain dumps unexpectedly enabled archive compression" >&2
    exit 1
fi

cat >"$temporary/unsafe-name.env" <<'EOF'
PGHOST=/var/run/postgresql
PGPORT=5431
PGUSER=postgres
PG_BACKUP_MODE=logical
PG_LOGICAL_FILE_NAMING=plain
EOF
mkdir "$temporary/unsafe-name"
if PATH="$temporary/bin:$PATH" DRIVER_CONFIG="$temporary/unsafe-name.env" \
    BACKUP_NAME=test-unsafe TEST_DATABASE_OUTPUT='nested/database' \
    TEST_DUMP_LOG="$temporary/unsafe-dumps" \
    TEST_DUMP_ARGUMENT_LOG="$temporary/unsafe-dump-arguments" \
    "$ROOT/drivers/postgres/driver" prepare "$temporary/unsafe-name" \
    2>"$temporary/unsafe-error"; then
    echo "path-unsafe plain database name unexpectedly succeeded" >&2
    exit 1
fi
grep -- 'database name cannot be used as a plain filename' \
    "$temporary/unsafe-error" >/dev/null

cat >"$temporary/invalid-format.env" <<'EOF'
PGHOST=/var/run/postgresql
PGPORT=5431
PGUSER=postgres
PG_BACKUP_MODE=logical
PG_LOGICAL_FORMAT=invalid
EOF
if PATH="$temporary/bin:$PATH" DRIVER_CONFIG="$temporary/invalid-format.env" \
    "$ROOT/drivers/postgres/driver" healthcheck \
    2>"$temporary/invalid-format-error"; then
    echo "invalid logical format unexpectedly succeeded" >&2
    exit 1
fi
grep -- 'PG_LOGICAL_FORMAT must be custom or plain' \
    "$temporary/invalid-format-error" >/dev/null

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
    TEST_DUMP_ARGUMENT_LOG="$temporary/missing-dump-arguments" \
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
