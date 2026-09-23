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
printf '%s\n' "$*" >>"$TEST_MONGOSH_LOG"
# Execute the actual discovery JavaScript, with only the database connection
# mocked. This checks credential encoding and TLS options rather than accepting
# arbitrary/unsupported CLI flags as the old stub did.
[[ "$1" == --nodb && "$2" == --quiet && "$3" == --norc && "$4" == --eval ]]
node - "$5" <<'JS'
const assert = require('node:assert/strict');
const vm = require('node:vm');
const env = process.env;
const expression = process.argv[2];
for (const key of ['MONGODB_PASSWORD', 'MONGODB_TLS_CERTIFICATE_KEY_FILE_PASSWORD', 'MONGODB_URI']) {
    if (env[key]) assert.ok(!expression.includes(env[key]), `${key} leaked in argv`);
}
function Mongo(uri) {
    const parsed = new URL(uri);
    if (env.MONGODB_USERNAME) {
        assert.equal(decodeURIComponent(parsed.username), env.MONGODB_USERNAME);
        assert.equal(decodeURIComponent(parsed.password), env.MONGODB_PASSWORD || '');
    }
    assert.equal(parsed.searchParams.get('authSource'), env.MONGODB_AUTH_DATABASE);
    for (const [key, option] of [
        ['MONGODB_AUTH_MECHANISM', 'authMechanism'],
        ['MONGODB_TLS_CA_FILE', 'tlsCAFile'],
        ['MONGODB_TLS_CERTIFICATE_KEY_FILE', 'tlsCertificateKeyFile'],
        ['MONGODB_TLS_CERTIFICATE_KEY_FILE_PASSWORD', 'tlsCertificateKeyFilePassword']
    ]) {
        if (env[key]) assert.equal(parsed.searchParams.get(option), env[key]);
    }
    if (env.MONGODB_TLS_INSECURE === 'true') {
        for (const option of ['tls', 'tlsAllowInvalidCertificates', 'tlsAllowInvalidHostnames']) {
            assert.equal(parsed.searchParams.get(option), 'true');
        }
    } else {
        assert.equal(parsed.searchParams.get('tlsAllowInvalidCertificates'), null);
        assert.equal(parsed.searchParams.get('tlsAllowInvalidHostnames'), null);
    }
    if (env.TEST_MONGOSH_FAIL) throw new Error('sensitive URI: ' + uri);
    return {getDB(name) {
        assert.equal(name, 'admin');
        return {adminCommand(command) {
            if (command.listDatabases) {
                assert.equal(command.authorizedDatabases, true);
                return {ok: 1, databases: ['admin', 'analytics', 'app', 'config', 'local', 'scratch'].map(name => ({name}))};
            }
            assert.equal(command.hello, 1);
            return {ok: 1, setName: 'rs0', isWritablePrimary: false};
        }};
    }};
}
vm.runInNewContext(expression, {process, URLSearchParams, Mongo, print: console.log,
    quit: code => { throw new Error('discovery quit ' + code); }});
JS
EOF

cat >"$temporary/bin/mongodump" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
database= archive= out= config= gzip=false
for argument in "$@"; do
    case "$argument" in
        --config=*) config="${argument#*=}" ;;
        --password*|--uri*|--tls*|--sslPEMKeyPassword*)
            echo "unsafe or unsupported mongodump argument" >&2; exit 1 ;;
        --db=*) database="${argument#*=}" ;;
        --archive=*) archive="${argument#*=}" ;;
        --out=*) out="${argument#*=}" ;;
        --gzip) gzip=true ;;
    esac
done
[[ -n "$database" && -f "$config" ]]
[[ "$(stat -c %a "$config")" == 600 ]]
jq -e '.uri == env.MONGODB_URI and
    (.password // "") == (env.MONGODB_PASSWORD // "") and
    (.sslPEMKeyPassword // "") == (env.MONGODB_TLS_CERTIFICATE_KEY_FILE_PASSWORD // "")' \
    "$config" >/dev/null
printf '%s\n' "$config" >>"$TEST_CONFIG_LOG"
if [[ "${TEST_DUMP_FAIL:-}" == signal ]]; then
    kill -TERM "$PPID"
    exit 1
fi
[[ "${TEST_DUMP_FAIL:-}" != true ]] || exit 1
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
# A dedicated temp root makes leaked credentials observable after every run.
mkdir "$temporary/credentials"
export TMPDIR="$temporary/credentials"
export TEST_CONFIG_LOG="$temporary/config-paths"

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
if grep -E -- '--password|--uri=|--sslPEMKeyPassword|secret' "$temporary/archive-arguments"; then
    echo "secret found in dump arguments" >&2
    exit 1
fi
[[ -z "$(find "$TMPDIR" -mindepth 1 -print -quit)" ]]

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

# Secret-file precedence, escaping, TLS for both tools, and cleanup on failure.
cat >"$temporary/tls.env" <<'EOF'
MONGODB_URI=mongodb://127.0.0.1:27017/?replicaSet=rs0
MONGODB_USERNAME=policy-user
MONGODB_PASSWORD=policy-password
MONGODB_DATABASE_INCLUDE=app
MONGODB_TLS_CA_FILE='/test/CA bundle.pem'
MONGODB_TLS_CERTIFICATE_KEY_FILE='/test/client key.pem'
MONGODB_TLS_INSECURE=true
EOF
cat >"$temporary/secret.env" <<'EOF'
MONGODB_USERNAME='backup+user@example.org'
MONGODB_PASSWORD=$'password:"quotes"\\spaces @&+%\nsecond line'
MONGODB_TLS_CERTIFICATE_KEY_FILE_PASSWORD=$'PEM:"quotes"\\ @&+%\nsecond line'
MONGODB_AUTH_DATABASE='$external'
MONGODB_AUTH_MECHANISM=PLAIN
EOF
chmod 600 "$temporary/secret.env"
for failure in false true signal; do
    mkdir "$temporary/tls-$failure"
    status=0
    PATH="$temporary/bin:$PATH" DRIVER_CONFIG="$temporary/tls.env" \
        DRIVER_SECRET_FILE="$temporary/secret.env" TEST_DUMP_FAIL="$failure" \
        TEST_MONGOSH_LOG="$temporary/tls-mongosh" \
        TEST_DUMP_LOG="$temporary/tls-dumps" \
        TEST_DUMP_ARGUMENT_LOG="$temporary/tls-arguments" \
        "$ROOT/drivers/mongodb/driver" prepare "$temporary/tls-$failure" \
        >"$temporary/tls-output" 2>"$temporary/tls-error" || status=$?
    if [[ "$failure" == false ]]; then
        [[ "$status" == 0 ]]
    else
        [[ "$status" != 0 ]]
        grep -- 'mongodump failed' "$temporary/tls-error" >/dev/null
    fi
    [[ -z "$(find "$TMPDIR" -mindepth 1 -print -quit)" ]]
done
for option in --ssl --sslCAFile= --sslPEMKeyFile= --sslAllowInvalidCertificates --sslAllowInvalidHostnames; do
    grep -- "$option" "$temporary/tls-arguments" >/dev/null
done
if grep -E 'policy-password|password:"quotes"|PEM:"quotes"' "$temporary/tls-arguments" "$temporary/tls-mongosh"; then
    echo "TLS credentials leaked in argv" >&2
    exit 1
fi
if PATH="$temporary/bin:$PATH" DRIVER_CONFIG="$temporary/tls.env" \
    DRIVER_SECRET_FILE="$temporary/secret.env" TEST_MONGOSH_FAIL=true \
    TEST_MONGOSH_LOG="$temporary/failed-mongosh" \
    "$ROOT/drivers/mongodb/driver" connectivitycheck \
    >"$temporary/discovery-error" 2>&1; then
    echo "failed authentication unexpectedly succeeded" >&2
    exit 1
fi
if grep -E 'sensitive URI:|policy-password|second.line' "$temporary/discovery-error"; then
    echo "connection error leaked credentials" >&2
    exit 1
fi
cat >"$temporary/invalid-tls.env" <<'EOF'
MONGODB_URI=mongodb://127.0.0.1:27017/
MONGODB_TLS_INSECURE=maybe
EOF
if DRIVER_CONFIG="$temporary/invalid-tls.env" "$ROOT/drivers/mongodb/driver" healthcheck \
    2>"$temporary/invalid-tls-error"; then
    echo "invalid TLS Boolean unexpectedly succeeded" >&2
    exit 1
fi
grep -- 'MONGODB_TLS_INSECURE must be true or false' "$temporary/invalid-tls-error" >/dev/null
while IFS= read -r config; do
    [[ ! -e "$config" ]]
done <"$TEST_CONFIG_LOG"

echo "MongoDB driver tests passed"
