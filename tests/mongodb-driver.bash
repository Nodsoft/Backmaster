#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT
temporary="$(mktemp -d)"
readonly temporary
trap 'rm -rf -- "$temporary"' EXIT
mkdir -p "$temporary/bin"

cat >"$temporary/bin/mongosh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "${TEST_DISCOVERY_JSON:-{\"databases\":[\"admin\",\"analytics\",\"app\",\"config\",\"local\",\"scratch\"],\"topology\":\"replica-set\",\"set_name\":\"rs0\",\"writable_primary\":false}}"
printf '%s\n' "$*" >>"$TEST_MONGOSH_LOG"
EOF

cat >"$temporary/bin/mongodump" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
database= archive= out= gzip=false
for argument in "$@"; do
    case "$argument" in
        --db=*) database="${argument#*=}" ;;
        --archive=*) archive="${argument#*=}" ;;
        --out=*) out="${argument#*=}" ;;
        --gzip) gzip=true ;;
    esac
done
[[ -n "$database" ]]
if [[ -n "$archive" ]]; then
    mkdir -p "$(dirname -- "$archive")"
    printf 'archive of %s\n' "$database" >"$archive"
else
    mkdir -p "$out/$database"
    printf 'bson of %s\n' "$database" >"$out/$database/widgets.bson"
    [[ "$gzip" == false ]] || mv "$out/$database/widgets.bson" \
        "$out/$database/widgets.bson.gz"
fi
printf '%s\n' "$database" >>"$TEST_DUMP_LOG"
printf '%s\n' "$*" >>"$TEST_DUMP_ARGUMENT_LOG"
EOF
chmod +x "$temporary/bin/"*

cat >"$temporary/archive.env" <<'EOF'
MONGODB_URI=mongodb://127.0.0.1:27017/
MONGODB_USERNAME=backup
MONGODB_PASSWORD=secret
MONGODB_DATABASE_INCLUDE=$'analytics\napp\nscratch'
MONGODB_DATABASE_EXCLUDE=scratch
MONGODB_DUMP_FORMAT=archive
MONGODB_FILE_NAMING=plain
MONGODB_GZIP=true
MONGODB_NUM_PARALLEL_COLLECTIONS=8
EOF
archive_payload="$temporary/archive"
mkdir "$archive_payload"
PATH="$temporary/bin:$PATH" DRIVER_CONFIG="$temporary/archive.env" \
    TEST_MONGOSH_LOG="$temporary/mongosh-log" \
    TEST_DUMP_LOG="$temporary/archive-dumps" \
    TEST_DUMP_ARGUMENT_LOG="$temporary/archive-arguments" \
    "$ROOT/drivers/mongodb/driver" prepare "$archive_payload"
[[ "$(<"$temporary/archive-dumps")" == $'analytics\napp' ]]
[[ -s "$archive_payload/databases/analytics.archive.gz" ]]
[[ -s "$archive_payload/databases/app.archive.gz" ]]
[[ "$(jq -r '.format' "$archive_payload/databases.json")" == \
    backmaster-mongodb-logical-v1 ]]
[[ "$(jq -r '.source_topology' "$archive_payload/databases.json")" == replica-set ]]
[[ "$(jq -r '.source_set_name' "$archive_payload/databases.json")" == rs0 ]]
[[ "$(jq -r '.databases[].path' "$archive_payload/databases.json")" == \
    $'databases/analytics.archive.gz\ndatabases/app.archive.gz' ]]
grep -- '--numParallelCollections=8' "$temporary/archive-arguments" >/dev/null
grep -- '--gzip' "$temporary/archive-arguments" >/dev/null
grep -- '--username=backup' "$temporary/archive-arguments" >/dev/null
grep -- '--password=secret' "$temporary/archive-arguments" >/dev/null

cat >"$temporary/directory.env" <<'EOF'
MONGODB_URI=mongodb://127.0.0.1:27017/
MONGODB_DUMP_FORMAT=directory
MONGODB_FILE_NAMING=sha256
MONGODB_GZIP=false
MONGODB_DATABASE_INCLUDE=app
MONGODB_DUMP_DB_USERS_AND_ROLES=true
MONGODB_READ_PREFERENCE=secondaryPreferred
EOF
directory_payload="$temporary/directory"
mkdir "$directory_payload"
PATH="$temporary/bin:$PATH" DRIVER_CONFIG="$temporary/directory.env" \
    TEST_MONGOSH_LOG="$temporary/directory-mongosh" \
    TEST_DUMP_LOG="$temporary/directory-dumps" \
    TEST_DUMP_ARGUMENT_LOG="$temporary/directory-arguments" \
    "$ROOT/drivers/mongodb/driver" prepare "$directory_payload"
directory_path="$(jq -r '.databases[0].path' "$directory_payload/databases.json")"
[[ "$directory_path" =~ ^databases/[0-9a-f]{64}\.dump$ ]]
[[ -s "$directory_payload/$directory_path/app/widgets.bson" ]]
grep -- '--dumpDbUsersAndRoles' "$temporary/directory-arguments" >/dev/null
grep -- '--readPreference=secondaryPreferred' "$temporary/directory-arguments" >/dev/null
if grep -- '--gzip' "$temporary/directory-arguments" >/dev/null; then
    echo "uncompressed directory dump unexpectedly used gzip" >&2
    exit 1
fi

cat >"$temporary/system.env" <<'EOF'
MONGODB_URI=mongodb://127.0.0.1:27017/
MONGODB_INCLUDE_SYSTEM_DATABASES=true
MONGODB_DATABASE_INCLUDE=admin
EOF
mkdir "$temporary/system"
PATH="$temporary/bin:$PATH" DRIVER_CONFIG="$temporary/system.env" \
    TEST_MONGOSH_LOG="$temporary/system-mongosh" \
    TEST_DUMP_LOG="$temporary/system-dumps" \
    TEST_DUMP_ARGUMENT_LOG="$temporary/system-arguments" \
    "$ROOT/drivers/mongodb/driver" prepare "$temporary/system"
[[ "$(<"$temporary/system-dumps")" == admin ]]

cat >"$temporary/missing.env" <<'EOF'
MONGODB_URI=mongodb://127.0.0.1:27017/
MONGODB_DATABASE_INCLUDE=missing
EOF
mkdir "$temporary/missing"
if PATH="$temporary/bin:$PATH" DRIVER_CONFIG="$temporary/missing.env" \
    TEST_MONGOSH_LOG="$temporary/missing-mongosh" \
    TEST_DUMP_LOG="$temporary/missing-dumps" \
    TEST_DUMP_ARGUMENT_LOG="$temporary/missing-arguments" \
    "$ROOT/drivers/mongodb/driver" prepare "$temporary/missing" \
    2>"$temporary/missing-error"; then
    echo "missing included database unexpectedly succeeded" >&2
    exit 1
fi
grep -- 'included database does not exist or is not authorized' \
    "$temporary/missing-error" >/dev/null

cat >"$temporary/invalid.env" <<'EOF'
MONGODB_URI=mongodb://127.0.0.1:27017/
MONGODB_GZIP=maybe
EOF
if PATH="$temporary/bin:$PATH" DRIVER_CONFIG="$temporary/invalid.env" \
    "$ROOT/drivers/mongodb/driver" healthcheck \
    2>"$temporary/invalid-error"; then
    echo "invalid Boolean unexpectedly succeeded" >&2
    exit 1
fi
grep -- 'MONGODB_GZIP must be true or false' "$temporary/invalid-error" >/dev/null

PATH="$temporary/bin:$PATH" DRIVER_CONFIG="$temporary/archive.env" \
    TEST_MONGOSH_LOG="$temporary/health-mongosh" \
    TEST_DUMP_LOG="$temporary/health-dumps" \
    TEST_DUMP_ARGUMENT_LOG="$temporary/health-arguments" \
    "$ROOT/drivers/mongodb/driver" healthcheck >"$temporary/health-output"
grep -- 'topology=replica-set set=rs0 visible_databases=6' \
    "$temporary/health-output" >/dev/null

echo "MongoDB driver tests passed"
