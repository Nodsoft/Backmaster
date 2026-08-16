# systemd units and timers

Backmaster uses systemd template units so one installation can run several
independent backup instances. The text between `@` and the unit suffix is the
Backmaster instance name. For example,
`backmaster@production-postgres.service` loads
`/etc/backmaster/instances.d/production-postgres.env`.

Instance names must start with a lowercase letter or digit and contain only
lowercase letters, digits, and hyphens. Use the same name in the systemd unit,
instance filename, and `INSTANCE_NAME` setting.

## Installed units

`backmaster-core` installs these reusable units in
`/usr/lib/systemd/system/`:

| Unit | Purpose | Installed schedule |
| --- | --- | --- |
| `backmaster@.service` | Run a backup attempt for an instance | None |
| `backmaster-health@.service` | Check the driver and exporter | Hourly |
| `backmaster-health@.timer` | Trigger the matching health service | `hourly` |

The package deliberately does not install `backmaster@.timer`. Backup cadence
depends on the database, recovery objectives, maintenance window, and fleet
fallback design. Create an instance-specific timer as described below. The
files under `deploy/axon/` and `deploy/myelin/` are examples, not automatically
enabled system units.

Do not edit files below `/usr/lib/systemd/system`; package upgrades replace
them. Put instance timers and service drop-ins below `/etc/systemd/system`.

## Before creating a timer

Complete the [installation](installation.md) and
[configuration](configuration.md) guides first. Confirm the three names agree:

```bash
instance=production-postgres
grep '^INSTANCE_NAME=' "/etc/backmaster/instances.d/$instance.env"
systemctl cat "backmaster@$instance.service"
```

Validate the source and destination as the account that will run the service.
For the PostgreSQL driver this is normally `postgres`:

```bash
sudo -u postgres backmaster connectivity production-postgres
```

Do not enable unattended backups until an intentional service run succeeds and
an isolated restore test has passed.

## Configure the service identity

The packaged service templates run as the unprivileged `backmaster` user. A
driver that needs a different operating-system identity must override both the
backup and health services. PostgreSQL deployments using local peer
authentication normally run as `postgres`:

```bash
sudo install -d -m 0755 \
  /etc/systemd/system/backmaster@production-postgres.service.d \
  /etc/systemd/system/backmaster-health@production-postgres.service.d

sudo tee \
  /etc/systemd/system/backmaster@production-postgres.service.d/driver.conf \
  >/dev/null <<'EOF'
[Unit]
After=patroni.service

[Service]
User=postgres
Group=postgres
EOF

health_dropin=/etc/systemd/system/\
backmaster-health@production-postgres.service.d/driver.conf
sudo tee "$health_dropin" >/dev/null <<'EOF'
[Service]
User=postgres
Group=postgres
EOF
```

Replace `patroni.service` with the local PostgreSQL unit, or omit that ordering
line when no explicit dependency is required. `After=` controls order only; it
does not start the named service. Add `Wants=` or `Requires=` only when that
lifecycle coupling is intentional.

The template's `StateDirectory=backmaster/%i` makes systemd create
`/var/lib/backmaster/INSTANCE` for the effective `User=` and `Group=` before
each run. This is why backup runs should normally start through systemd instead
of with a direct `sudo -u ... backmaster run` command.

Reload systemd and inspect the merged unit, including all drop-ins:

```bash
sudo systemctl daemon-reload
systemctl cat backmaster@production-postgres.service
systemctl cat backmaster-health@production-postgres.service
systemctl show backmaster@production-postgres.service \
  -p User -p Group -p StateDirectory -p ReadWritePaths
```

## Run and verify the service

Start a commissioning backup through the oneshot service:

```bash
sudo systemctl start backmaster@production-postgres.service
systemctl status backmaster@production-postgres.service
journalctl -u backmaster@production-postgres.service -n 200 --no-pager
```

`systemctl start` waits for a oneshot unit to finish. In another terminal, use
`journalctl -f` to follow a long run. For an asynchronous start, use
`systemctl start --no-block` and then inspect the unit and journal.

A successful service can later appear as `inactive (dead)`: that is normal for
`Type=oneshot`. Check `Result`, `ExecMainStatus`, and timestamps when diagnosing
the last invocation:

```bash
systemctl show backmaster@production-postgres.service \
  -p Result -p ExecMainStatus -p ActiveEnterTimestamp -p InactiveEnterTimestamp
```

## Create a backup timer

Create an instance-specific timer in `/etc/systemd/system`. This example makes
a daily attempt at 02:15 UTC and adds up to five minutes of jitter:

```bash
sudo tee /etc/systemd/system/backmaster@production-postgres.timer \
  >/dev/null <<'EOF'
[Unit]
Description=Daily Backmaster attempt for production-postgres

[Timer]
OnCalendar=*-*-* 02:15:00 UTC
Persistent=true
RandomizedDelaySec=5m
Unit=backmaster@production-postgres.service

[Install]
WantedBy=timers.target
EOF
```

`Persistent=true` causes one catch-up run after the machine returns if the
calendar event was missed while the timer was inactive. It does not replay
every missed event. `RandomizedDelaySec` spreads load, so account for the delay
when defining freshness and fallback windows.

Validate the calendar and unit files before enabling them:

```bash
systemd-analyze calendar '*-*-* 02:15:00 UTC'
sudo systemctl daemon-reload
systemd-analyze verify \
  /etc/systemd/system/backmaster@production-postgres.timer \
  /usr/lib/systemd/system/backmaster@.service
```

Enable and start the backup and health timers:

```bash
sudo systemctl enable --now \
  backmaster@production-postgres.timer \
  backmaster-health@production-postgres.timer

systemctl list-timers --all 'backmaster*'
systemctl status backmaster@production-postgres.timer
systemctl status backmaster-health@production-postgres.timer
```

Enabling creates boot-time links; `--now` also starts the timers immediately.
Starting a timer does not immediately run its service unless a persistent event
is overdue. Start the service explicitly for an immediate backup.

## Change an existing schedule

Once the instance timer exists, use a drop-in to keep local schedule changes
separate from the base unit:

```bash
sudo systemctl edit backmaster@production-postgres.timer
```

An `OnCalendar=` list is cumulative. Reset it with an empty assignment before
setting the replacement:

```ini
[Timer]
OnCalendar=
OnCalendar=Mon..Sat *-*-* 01:30:00 UTC
RandomizedDelaySec=10m
```

Then reload and confirm the effective schedule:

```bash
sudo systemctl daemon-reload
systemctl cat backmaster@production-postgres.timer
systemctl list-timers --all backmaster@production-postgres.timer
```

For a one-off calendar expression, `systemd-analyze calendar` shows the next
elapse times without changing the unit.

## Preferred and fallback nodes

Give every capable node the same instance name, destination, Consul lock key,
freshness threshold, and package version. Give each node a distinct
`NODE_NAME`, point it at its local database member, and install a local timer
with a different schedule.

For example, schedule the preferred node at 02:15 UTC and a fallback at 03:15
UTC. The fallback checks the shared remote catalogue and exits with
`reason=fresh_backup_exists` when the preferred backup is still fresh. The gap
must exceed the preferred node's usual backup duration plus both timers' jitter.
`MAX_AGE_SECONDS` must keep the preferred backup fresh throughout that window.

Timers and Consul solve different problems: timers initiate attempts, while the
distributed lock prevents simultaneous creation. Keep both protections.

## Health timer and alerting

The packaged health timer runs hourly:

```bash
systemctl cat backmaster-health@.timer
sudo systemctl enable --now backmaster-health@production-postgres.timer
```

Override its schedule with `systemctl edit` if necessary, resetting
`OnCalendar=` as shown above. A timer successfully triggering a failed oneshot
service does not make the timer unit itself fail. Monitor and alert on the
service result or journal, not only on whether the timer is active:

```bash
systemctl --failed 'backmaster*'
journalctl -u backmaster-health@production-postgres.service \
  --since today --no-pager
```

## Sandboxing and custom paths

The packaged services use `ProtectSystem=strict`, `ProtectHome=true`, and
explicit writable paths. Configuration under `/etc/backmaster` is readable but
not writable. The default state directory is writable. AzCopy logs and job
plans therefore default below the per-instance Backmaster state directory.

If `STAGING_ROOT` or an exporter state path is moved elsewhere, grant only the
required path in drop-ins for both services that use it:

```ini
[Service]
ReadWritePaths=/srv/backmaster/production-postgres
```

Create the directory with the service user's ownership, reload systemd, and
confirm the merged `ReadWritePaths=`. Do not weaken the sandbox with a broad
writable filesystem or put credentials directly in a unit's `Environment=`.
Use Backmaster's protected secret files instead.

## Timeouts and resource policy

The backup template permits a run of up to 12 hours and applies lower CPU and
I/O priority. Override only the values justified by measured backup duration:

```ini
[Service]
TimeoutStartSec=18h
Nice=5
```

A systemd timeout terminates the backup. Backmaster retains a sealed `.ready`
stage after an interrupted export and publishes it on the next attempt. An
interrupted driver preparation leaves a `.partial.*` directory for operator
inspection; it is not automatically resumed.

## Disable or remove a schedule

Stop future attempts while leaving the service available for manual starts:

```bash
sudo systemctl disable --now backmaster@production-postgres.timer
```

To remove a locally created timer and its overrides:

```bash
sudo systemctl disable --now backmaster@production-postgres.timer
sudo rm /etc/systemd/system/backmaster@production-postgres.timer
sudo rm -rf \
  /etc/systemd/system/backmaster@production-postgres.timer.d
sudo systemctl daemon-reload
sudo systemctl reset-failed backmaster@production-postgres.service
```

Removing a timer does not delete instance configuration, staged data, or remote
backups.

## Troubleshooting checklist

Use these checks in order:

1. `systemctl cat UNIT` confirms the base unit and every active drop-in.
2. `systemctl list-timers --all 'backmaster*'` shows last and next triggers.
3. `systemctl status UNIT` shows the last result and immediate errors.
4. `journalctl -u UNIT -n 200 --no-pager` shows Backmaster and child output.
5. `systemctl show SERVICE -p User -p Group -p StateDirectory -p ReadWritePaths`
   confirms identity and writable paths.
6. `systemd-analyze verify UNIT_FILE` catches unit syntax errors.

Common causes include:

- `Unit ...timer not found`: create the instance-specific backup timer; only
  the health timer template is packaged.
- `Permission denied` below `/var/lib/backmaster`: start through systemd and
  confirm the driver identity drop-in applies to both services.
- a timer is active but no backup appears: inspect the triggered service; a
  fresh remote backup can cause a successful skip.
- schedule changes are ignored: clear inherited `OnCalendar=` values, reload
  systemd, and inspect the merged timer.
- a unit works manually but fails from the timer: compare the effective service
  user, protected paths, secret-file permissions, and journal from the timed
  invocation.

Continue with the [operations guide](operations.md) for staging, retention,
monitoring, upgrades, and restore-drill policy.
