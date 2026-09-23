#!/usr/bin/env bash
# Real-tool regression: requires mongod, mongosh, mongodump, mongorestore and openssl.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT
temporary="$(mktemp -d)"
readonly temporary
cleanup() {
    local name
    for name in source target; do
        if [[ -f "$temporary/$name.pid" ]]; then
            kill "$(<"$temporary/$name.pid")" 2>/dev/null || true
        fi
    done
    rm -rf -- "$temporary"
}
trap cleanup EXIT
umask 077
mkdir "$temporary/source" "$temporary/target" "$temporary/credentials"
export TMPDIR="$temporary/credentials"
# These credentials are generated test fixtures, never production credentials.
export MONGODB_USERNAME=backup
export MONGODB_PASSWORD=$'test:"quotes"\\ @&+% unicode-é'
export MONGODB_TLS_CERTIFICATE_KEY_FILE_PASSWORD='test PEM: @&+%'
export MONGODB_URI='mongodb://localhost:29717/?serverSelectionTimeoutMS=3000'
export MONGODB_AUTH_DATABASE=admin

start_server() {
    local name="$1" port="$2"
    shift 2
    mongod --dbpath "$temporary/$name" --port "$port" --bind_ip 127.0.0.1 \
        --pidfilepath "$temporary/$name.pid" --logpath "$temporary/$name.log" \
        --fork "$@" >/dev/null
}
start_server source 29717
mongosh 'mongodb://localhost:29717/' --quiet --norc --eval '
    db.getSiblingDB("admin").createUser({user:process.env.MONGODB_USERNAME,
        pwd:process.env.MONGODB_PASSWORD,roles:["root"]});
    const app = db.getSiblingDB("application");
    app.widgets.insertOne({value:42});
    app.createRole({role:"widgetReader",privileges:[{resource:{db:"application",collection:"widgets"},actions:["find"]}],roles:[]});
    app.createUser({user:"reader",pwd:"test-reader-password",roles:["widgetReader"]});
' >/dev/null
mongod --dbpath "$temporary/source" --shutdown >/dev/null
rm -f "$temporary/source.pid"

openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=localhost' \
    -addext 'subjectAltName=DNS:localhost' \
    -keyout "$temporary/key.pem" -out "$temporary/ca.pem" 2>/dev/null
cat "$temporary/key.pem" "$temporary/ca.pem" >"$temporary/server.pem"
openssl pkey -in "$temporary/key.pem" -aes256 \
    -passout env:MONGODB_TLS_CERTIFICATE_KEY_FILE_PASSWORD \
    -out "$temporary/client-key.pem" 2>/dev/null
cat "$temporary/client-key.pem" "$temporary/ca.pem" >"$temporary/client.pem"
start_server source 29717 --auth --tlsMode requireTLS \
    --tlsCertificateKeyFile "$temporary/server.pem" --tlsCAFile "$temporary/ca.pem"
start_server target 29718

export MONGODB_TLS_CA_FILE="$temporary/ca.pem"
export MONGODB_TLS_CERTIFICATE_KEY_FILE="$temporary/client.pem"
cat >"$temporary/driver.env" <<'CONFIG'
MONGODB_DATABASE_INCLUDE=application
MONGODB_DUMP_DB_USERS_AND_ROLES=true
CONFIG
export DRIVER_CONFIG="$temporary/driver.env"
"$ROOT/drivers/mongodb/driver" connectivitycheck
"$ROOT/drivers/mongodb/driver" healthcheck
for format in archive directory; do
    export MONGODB_DUMP_FORMAT="$format"
    export MONGODB_GZIP=false
    mkdir "$temporary/$format"
    "$ROOT/drivers/mongodb/driver" prepare "$temporary/$format"
    dump_path="$(jq -r '.databases[0].path' "$temporary/$format/databases.json")"
    restore_args=(--uri=mongodb://localhost:29718/ --db=application --restoreDbUsersAndRoles)
    if [[ "$format" == archive ]]; then
        restore_args+=(--archive="$temporary/$format/$dump_path")
    else
        restore_args+=("$temporary/$format/$dump_path/application")
    fi
    mongorestore "${restore_args[@]}" >/dev/null
    mongosh 'mongodb://localhost:29718/' --quiet --norc --eval '
        const app = db.getSiblingDB("application");
        if (app.widgets.countDocuments({value:42}) !== 1 || !app.getUser("reader") ||
            !app.getRole("widgetReader")) throw new Error("restore validation failed");
        app.dropAllUsers(); app.dropAllRoles(); app.dropDatabase();
    ' >/dev/null
done
# A valid CA with an IP hostname absent from its SAN must fail securely.
export MONGODB_URI='mongodb://127.0.0.1:29717/?serverSelectionTimeoutMS=3000'
if "$ROOT/drivers/mongodb/driver" connectivitycheck >"$temporary/rejected" 2>&1; then
    echo 'invalid TLS hostname unexpectedly accepted' >&2
    exit 1
fi
# The explicit diagnostic override must work in both discovery and mongodump.
export MONGODB_TLS_INSECURE=true MONGODB_GZIP=true MONGODB_DUMP_FORMAT=archive
mkdir "$temporary/insecure"
"$ROOT/drivers/mongodb/driver" prepare "$temporary/insecure"
mongorestore --uri=mongodb://localhost:29718/ --gzip \
    --archive="$temporary/insecure/databases/application.archive.gz" \
    --nsFrom='application.*' --nsTo='renamed.*' >/dev/null
mongosh 'mongodb://localhost:29718/' --quiet --norc --eval '
    if (db.getSiblingDB("renamed").widgets.countDocuments({value:42}) !== 1)
        throw new Error("renamed gzip restore failed");
' >/dev/null
[[ -z "$(find "$TMPDIR" -mindepth 1 -print -quit)" ]]
echo 'MongoDB real-tool TLS, authentication, dump and restore tests passed'
