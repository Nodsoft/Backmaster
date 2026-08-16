# MongoDB restore runbook

Restore into an isolated MongoDB deployment first. Never point an unreviewed
restore at production: `mongorestore` can insert into existing collections and
options such as `--drop` are destructive.

## 1. Select and verify the Backmaster backup

Choose a backup with a committed `manifest.json`. Download the manifest and
either its individual-file payload or the single archive named in
`manifest.artifact`. Follow the archive extraction and checksum procedure in
the [operations guide](operations.md#restore-and-verification). Do not continue
until the outer archive digest, when present, and `checksums.sha256` both pass.

The extracted MongoDB payload contains `payload/databases.json`. Inspect it:

```bash
jq . payload/databases.json
jq -r '.databases[] | [.database, .path] | @tsv' \
  payload/databases.json
```

Do not infer database names from hashed paths. The index is authoritative.

## 2. Prepare the target

Install a compatible `mongorestore` from MongoDB Database Tools. Create a target
deployment whose version and feature compatibility version are compatible with
the dump. Provision enough capacity for data, indexes, and restore working
space. Keep application clients disconnected until validation finishes.

Store target credentials in a protected shell variable or tool configuration;
do not reuse the production backup credential. The examples use:

```bash
target_uri='mongodb://127.0.0.1:27018/'
target_database='application-restore'
```

Review the source database's collection validators, collation, indexes, views,
and user-defined roles. Decide whether identities should be restored or
recreated under target-specific policy.

## 3. Restore an archive dump

Resolve the indexed path rather than constructing it:

```bash
source_database='application'
dump_path="$(jq -er --arg database "$source_database" \
  '.databases[] | select(.database == $database) | .path' \
  payload/databases.json)"
gzip_enabled="$(jq -er '.gzip' payload/databases.json)"

restore_args=(--uri="$target_uri" --archive="payload/$dump_path")
[[ "$gzip_enabled" == false ]] || restore_args+=(--gzip)
restore_args+=(--nsFrom="${source_database}.*" \
  --nsTo="${target_database}.*")

mongorestore "${restore_args[@]}"
```

Omit `--nsFrom` and `--nsTo` to restore the original namespace. Add `--drop`
only after confirming the target is disposable or the replacement is explicitly
approved; it removes target collections before restoring them.

## 4. Restore a directory dump

The indexed path points to a top-level dump directory containing a nested
database directory:

```bash
source_database='application'
dump_path="$(jq -er --arg database "$source_database" \
  '.databases[] | select(.database == $database) | .path' \
  payload/databases.json)"
gzip_enabled="$(jq -er '.gzip' payload/databases.json)"

restore_args=(--uri="$target_uri")
[[ "$gzip_enabled" == false ]] || restore_args+=(--gzip)
restore_args+=(--nsFrom="${source_database}.*" \
  --nsTo="${target_database}.*" "payload/$dump_path")

mongorestore "${restore_args[@]}"
```

Use `--nsInclude` or `--nsExclude` for a controlled collection subset. Preview
the index and directory contents first; namespace patterns are evaluated by
`mongorestore`, not Backmaster.

## 5. Validate the restored database

At minimum:

1. Compare collection and view inventories.
2. Compare document counts, understanding that live-source writes may make
   counts differ between separately timed observations.
3. Confirm validators, collection options, and indexes.
4. Exercise representative application reads against the isolated target.
5. Review `mongorestore` output for skipped or failed documents and indexes.
6. Record the backup name, restore duration, target version, and validation
   result in the restore-drill log.

For a database with critical cross-collection invariants, run application-level
integrity checks. A successful command exit is not proof that the restored
application state is usable.

## Consistency limitations

Backmaster invokes `mongodump --db` separately for each selected database.
MongoDB's `--oplog` option cannot be combined with per-database dumps, so the
driver does not claim a deployment-wide snapshot or PITR. Transactions and
writes spanning separate database dump windows may not be mutually consistent.
Use a storage snapshot or MongoDB backup product designed for deployment-wide
consistency when that recovery property is required.
