# PostgreSQL restore runbook

This runbook restores physical and logical PostgreSQL backups produced by
Backmaster. Perform recovery on an isolated host or network. Never point an
unverified restore at production clients, Patroni DCS, or the production member
port.

The base backup is a compressed tar-format `pg_basebackup`. Streamed WAL makes
it self-contained to the end of the backup. Separately archived WAL supports
point-in-time recovery beyond that point.

A logical payload instead contains `globals.sql.gz`, `databases.json`, and one
custom or plain SQL dump per selected database. It supports selective restore and
major-version migration subject to PostgreSQL compatibility, but not PITR or a
byte-for-byte Patroni member rebuild.

## Recovery decisions

Before touching data, record:

- the incident and recovery owner;
- target cluster/system identifier;
- chosen backup name and source node from its manifest;
- latest recovery or an exact target time/LSN/XID/name;
- target PostgreSQL major version and required extensions;
- whether this is a test, member rebuild, or total-cluster recovery.

Use PostgreSQL binaries compatible with the backup's major version. Backmaster
does not perform major-version conversion.

## 1. Select a committed backup

Load the exporter configuration in a protected root shell:

```bash
set -a
source /etc/backmaster/exporters/rclone/production-postgres.env
source /etc/backmaster/secrets/production-postgres-exporter.env
set +a

rclone lsf "$RCLONE_DESTINATION/basebackups" --dirs-only
```

Only choose a directory containing `manifest.json`; it is the commit marker.
Inspect the manifest before downloading:

```bash
backup_name=REPLACE_BACKUP_NAME
rclone cat \
  "$RCLONE_DESTINATION/basebackups/$backup_name/manifest.json" | jq .
```

Confirm `instance`, `driver`, `node`, `backup_name`, and `created_epoch` match the
intended recovery.

The optional `artifact` object describes whether the backup uses individual
files or one archive. Older manifests without that object use the `files`
layout.

## 2. Download and verify

Use a new local directory with enough room for both compressed archives and the
extracted data:

```bash
restore_root=/var/tmp/backmaster-restore
sudo install -d -m 0700 -o postgres -g postgres "$restore_root"
rclone copy \
  "$RCLONE_DESTINATION/basebackups/$backup_name" \
  "$restore_root"

cd "$restore_root"
```

For a files-layout backup, verify immediately:

```bash
sudo -u postgres sha256sum --check checksums.sha256
```

For an archive layout, download yields one `backup.*` file plus the manifest.
Verify the archive against `.artifact.sha256`, extract it into the restore root
using the format recorded in `.artifact.format`, then verify the payload
checksums stored inside it:

```bash
archive="$(jq -r '.artifact.file' manifest.json)"
printf '%s  %s\n' "$(jq -r '.artifact.sha256' manifest.json)" "$archive" | \
  sha256sum --check -
case "$(jq -r '.artifact.format' manifest.json)" in
  zip) unzip backup.zip ;;
  tar.gz) tar -xzf backup.tar.gz ;;
  tar.xz) tar -xJf backup.tar.xz ;;
  tar.zst) tar --zstd -xf backup.tar.zst ;;
  *) echo "unsupported backup archive format" >&2; exit 1 ;;
esac
sudo -u postgres sha256sum --check checksums.sha256
```

Extract into a new, empty, mode-`0700` restore directory and do not bypass the
checksum step. Archive mode optimizes whole-backup download and storage; use the
default files layout when routinely downloading individual database dumps is
more important.

Stop if any checksum fails. Preserve the downloaded files for investigation and
select another known-good backup.

`payload/backup_manifest` is PostgreSQL's own backup manifest. When supported by
the installed version, verify it after extraction with `pg_verifybackup` as an
additional check.

## Physical restore

The following physical procedure assumes the chosen payload contains
`base.tar` or a compressed variant. If it contains `databases.json`, use the
logical procedure below instead.

## 3. Prepare an empty data directory

The target below is an example. Resolve the exact PostgreSQL data path before
running any destructive command. Stop PostgreSQL/Patroni on the isolated host,
move any existing directory aside according to your recovery procedure, and
create an empty target:

```bash
restore_pgdata=/var/lib/postgresql/18/restore
sudo install -d -m 0700 -o postgres -g postgres "$restore_pgdata"
```

Do not extract over a live or non-empty cluster.

## 4. Extract the base backup

Inspect archive names and compression first:

```bash
find "$restore_root/payload" -maxdepth 1 -type f -printf '%f\n'
```

Extract `base.tar` or `base.tar.<compression-extension>` into the empty data
directory using a tar implementation that supports the selected compression.
For the default gzip compression:

```bash
sudo -u postgres tar -xzf "$restore_root/payload/base.tar.gz" \
  -C "$restore_pgdata"
```

If `pg_wal.tar.gz` exists, extract it into `pg_wal`:

```bash
sudo -u postgres install -d -m 0700 "$restore_pgdata/pg_wal"
sudo -u postgres tar -xzf "$restore_root/payload/pg_wal.tar.gz" \
  -C "$restore_pgdata/pg_wal"
```

For each tablespace archive, use `tablespace_map` to prepare the intended
tablespace directory and extract the matching archive there. Do not reuse
production tablespace paths for an isolated drill.

Finally:

```bash
sudo chown -R postgres:postgres "$restore_pgdata"
sudo chmod 0700 "$restore_pgdata"
```

## 5. Configure recovery

For recovery using archived WAL, make the Backmaster configuration and exporter
credentials readable by the isolated PostgreSQL service identity and set:

<!-- markdownlint-disable MD013 -->
```conf
restore_command = '/usr/bin/backmaster driver production-postgres wal-restore %f %p'
```
<!-- markdownlint-enable MD013 -->

Create the recovery signal:

```bash
sudo -u postgres touch "$restore_pgdata/recovery.signal"
```

For PITR, set exactly the intended PostgreSQL recovery target, for example:

```conf
recovery_target_time = '2026-08-03 01:40:00+00'
recovery_target_action = 'pause'
```

Use UTC and have another operator verify the target. Omitting a target recovers
as far as the available WAL permits. A missing WAL segment stops recovery; do
not silently promote before assessing the resulting consistency point.

## 6. Start isolated and validate

Start PostgreSQL on a non-production port without registering it as a production
Patroni member. Follow its log until recovery reaches the target.

Validate at minimum:

- PostgreSQL accepts local connections;
- expected databases, roles, extensions, and schemas exist;
- application consistency checks pass;
- the recovery timestamp/LSN matches the target;
- representative row counts and critical records are correct.

If recovery pauses at the target, inspect it before issuing the deliberate
promotion/resume action required by your PostgreSQL procedure.

## 7. Rebuild a Patroni cluster

For total cluster loss, recover exactly one authoritative node first. Validate
and promote it, then create or reinitialize Patroni/DCS around that node using
the established Patroni recovery procedure. Allow other members to clone from
the new authority.

Never start two independently restored copies as peers. That can create
divergent timelines and conflicting authority.

For an ordinary single-member loss while a healthy primary remains, prefer
Patroni's normal replica reinitialization. A full Backmaster restore is primarily
for loss of all viable cluster copies or for time-based recovery.

## Drill acceptance checklist

A production-ready flow has demonstrated:

- latest restore from every eligible producer node;
- checksum and PostgreSQL manifest verification;
- timestamped PITR using archived WAL;
- successful fallback when the preferred producer misses its window;
- application-level validation after recovery;
- measured recovery duration within the recovery-time objective;
- monitoring of base backups, WAL archival, and staging capacity.

Record the selected backup, target, commands, timings, validation results, and
cleanup after every drill.

## Logical restore

Restore logical backups into an already initialized, isolated PostgreSQL
cluster. Use client tools compatible with the dump format and review extension
and major-version compatibility before proceeding.

Inspect the database index:

```bash
jq . "$restore_root/payload/databases.json"
```

Restore cluster globals once, reviewing the SQL before execution because it can
create or alter roles and tablespaces:

```bash
gzip -dc "$restore_root/payload/globals.sql.gz" >"$restore_root/globals.sql"
less "$restore_root/globals.sql"
psql --set=ON_ERROR_STOP=1 --file="$restore_root/globals.sql" postgres
```

For each desired entry in `databases.json`, create an empty target database with
the intended owner, then restore its mapped dump. Read `dump_format` from the
index rather than relying only on the extension:

```bash
database=backmaster
dump_file="$(jq -r --arg database "$database" \
  '.databases[] | select(.database == $database) | .file' \
  "$restore_root/payload/databases.json")"
test -n "$dump_file" && test "$dump_file" != null
createdb --template=template0 "$database"
case "$(jq -r '.dump_format // "custom"' \
  "$restore_root/payload/databases.json")" in
  custom)
    pg_restore --exit-on-error --dbname="$database" \
      "$restore_root/payload/$dump_file"
    ;;
  plain)
    psql --set=ON_ERROR_STOP=1 --dbname="$database" \
      --file="$restore_root/payload/$dump_file"
    ;;
  *)
    echo "unsupported logical dump format" >&2
    exit 1
    ;;
esac
```

Use `--clean --if-exists` only when an intentional replacement workflow calls
for it; never point it at an unverified production target. Validate roles,
ownership, extensions, schemas, representative row counts, and application
behavior. A logical backup set is made sequentially: each database dump is
individually consistent, but cross-database state may represent different
moments.
