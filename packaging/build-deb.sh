#!/usr/bin/env bash
set -Eeuo pipefail

readonly ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly OUT_DIR="${OUT_DIR:-${ROOT}/dist}"
readonly ARCH="${ARCH:-$(dpkg --print-architecture)}"
readonly PACKAGE="backmaster"
readonly PKGROOT="${PKGROOT:-${ROOT}/pkgroot}"

VERSION="${VERSION:-}"
if [[ -z "$VERSION" ]]; then
    if command -v git >/dev/null 2>&1 && git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        VERSION="$(git -C "$ROOT" describe --tags --dirty --always | sed 's/^v//')"
    else
        VERSION="0.0.0"
    fi
fi

[[ "$VERSION" =~ ^[0-9][0-9A-Za-z.+:~-]*$ ]] || { echo "Invalid Debian version: $VERSION" >&2; exit 64; }
[[ "$ARCH" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "Invalid Debian architecture: $ARCH" >&2; exit 64; }

rm -rf -- "$PKGROOT"
mkdir -p "$OUT_DIR" "$PKGROOT/DEBIAN"
install -d -m 0755 \
    "$PKGROOT/usr/bin" \
    "$PKGROOT/usr/lib/backmaster/drivers/postgres" \
    "$PKGROOT/usr/lib/backmaster/exporters/rclone" \
    "$PKGROOT/usr/lib/systemd/system" \
    "$PKGROOT/usr/lib/sysusers.d" \
    "$PKGROOT/usr/share/doc/backmaster/examples" \
    "$PKGROOT/etc/backmaster/instances.d" \
    "$PKGROOT/etc/backmaster/drivers.d" \
    "$PKGROOT/etc/backmaster/exporters.d"

install -m 0755 "$ROOT/bin/backmaster" "$PKGROOT/usr/bin/backmaster"
install -m 0755 "$ROOT/drivers/postgres/driver" "$PKGROOT/usr/lib/backmaster/drivers/postgres/driver"
install -m 0755 "$ROOT/exporters/rclone/exporter" "$PKGROOT/usr/lib/backmaster/exporters/rclone/exporter"
install -m 0644 "$ROOT/systemd/"* "$PKGROOT/usr/lib/systemd/system/"
install -m 0644 "$ROOT/README.md" "$PKGROOT/usr/share/doc/backmaster/README.md"
install -m 0644 "$ROOT/docs/"*.md "$PKGROOT/usr/share/doc/backmaster/"
cp -a "$ROOT/config/." "$PKGROOT/usr/share/doc/backmaster/examples/config/"
cp -a "$ROOT/deploy/." "$PKGROOT/usr/share/doc/backmaster/examples/deploy/"

printf 'u backmaster - "Backmaster backup orchestrator" /var/lib/backmaster -\n' \
    >"$PKGROOT/usr/lib/sysusers.d/backmaster.conf"

sed -i "s|@BACKMASTER_VERSION@|${VERSION}|g" "$PKGROOT/usr/bin/backmaster"

cat >"$PKGROOT/DEBIAN/control" <<EOF
Package: $PACKAGE
Version: $VERSION
Section: admin
Priority: optional
Architecture: $ARCH
Maintainer: Nodsoft Systems <packages@nodsoft.net>
Depends: bash (>= 4.4), consul, coreutils, findutils, jq, systemd
Recommends: gzip, postgresql-client, rclone
Description: modular fleet backup orchestrator
 Backmaster coordinates distributed backup scheduling, locking, naming,
 staging, exporting, retention, and health reporting. It includes a PostgreSQL
 driver and an rclone exporter with reusable systemd service templates.
EOF

cat >"$PKGROOT/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e

if command -v systemd-sysusers >/dev/null 2>&1; then
    systemd-sysusers backmaster.conf >/dev/null 2>&1 || true
fi
if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload >/dev/null 2>&1 || true
fi
exit 0
EOF
chmod 0755 "$PKGROOT/DEBIAN/postinst"

cat >"$PKGROOT/DEBIAN/postrm" <<'EOF'
#!/bin/sh
set -e

if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload >/dev/null 2>&1 || true
fi
exit 0
EOF
chmod 0755 "$PKGROOT/DEBIAN/postrm"

readonly DEB_PATH="${OUT_DIR}/${PACKAGE}_${VERSION}_${ARCH}.deb"
dpkg-deb --root-owner-group --build "$PKGROOT" "$DEB_PATH"
echo "Built: $DEB_PATH"
