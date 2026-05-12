#!/bin/bash
# =============================================================================
# QManager — Installer for Telekom 5G Empfaenger (RG520NEUDB / Arcadyan)
# No Entware variant
# =============================================================================
#
# Targets the Telekom-customized RG520N hardware (Arcadyan firmware variant
# of the SDXLEMUR platform). Key differences from install_rm520n.sh:
#
#   * NO Entware bootstrap — /opt does not exist on the rootfs squashfs and
#     cannot be created (RO). All runtime tooling is satisfied from the
#     stock firmware:
#         curl     -> /usr/bin/wget   (1.20.3, +https +ssl/gnutls)
#         lighttpd -> /bin/busybox httpd  (CGI built in, no TLS needed
#                                          because access is via Tailscale)
#         sudo     -> not needed; httpd runs as root, platform.sh sets _SUDO=""
#         timeout  -> /usr/bin/timeout  (already present)
#         jq       -> bundled static armv7l binary in /usrdata/qmanager/bin/
#
#   * Read-only squashfs rootfs:  unit files go to /etc/systemd/system/
#     (writable, ubi2_0, slot-independent), NOT /lib/systemd/system/
#
#   * Tailscale aware: existing on-device install is preserved, the unit
#     for tailscaled is NOT overwritten.  Web UI install button is gated
#     by qmanager_tailscale_mgr's idempotency check.
#
#   * Discord bot / dropbear / Ookla speedtest are *omitted*; this variant
#     stays minimal and Tailscale-only.
#
# Usage:
#   bash install_telekom_se.sh                # interactive
#   bash install_telekom_se.sh --skip-restart # just install, don't restart svcs
#
# Run from the extracted archive:  bash /tmp/qmanager_install/install_telekom_se.sh
# =============================================================================

set -e

VERSION="dev"

# --- Detect/fail early -------------------------------------------------------

check_root() { [ "$(id -u)" -eq 0 ] || { echo "must be root" >&2; exit 1; }; }

check_platform() {
    if [ ! -d /usrdata ]; then
        echo "RG520N platform not detected (/usrdata missing)" >&2; exit 1
    fi
    # Confirm squashfs rootfs — the whole reason this installer exists
    if mount | grep -q "^/dev/ubiblock.* on / type squashfs"; then
        ROOTFS_RO=1
    else
        ROOTFS_RO=0
        echo "warning: rootfs is not squashfs RO — you might want the upstream install_rm520n.sh" >&2
    fi
}

# --- Source paths ------------------------------------------------------------

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_FRONTEND="$SRC_DIR/out"
SRC_SCRIPTS="$SRC_DIR/scripts"
SRC_DEPS="$SRC_DIR/dependencies"
SRC_TELEKOM_OVERRIDES="$SRC_DIR/telekom-cgi-overrides"

# --- Destination paths (writable on ubi2_0, slot-independent) ----------------

QMANAGER_ROOT="/usrdata/qmanager"
WWW_ROOT="/usrdata/qmanager/www"
CGI_DIR="/usrdata/qmanager/www/cgi-bin/quecmanager"
LIB_DIR="/usrdata/qmanager/lib"
BIN_DIR="/usrdata/qmanager/bin"
CONF_DIR="/etc/qmanager"
SYSTEMD_DIR="/etc/systemd/system"           # NOT /lib — see header
WANTS_DIR="/etc/systemd/system/multi-user.target.wants"

TAILSCALE_DIR="/usrdata/tailscale"
CERT_DIR="/usrdata/qmanager/certs"            # left for compatibility; unused
HTTPD_CONF="/usrdata/qmanager/httpd.conf"

# --- Helpers -----------------------------------------------------------------

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'
[ -t 1 ] || { GREEN=''; YELLOW=''; RED=''; CYAN=''; BOLD=''; NC=''; }

info()  { printf "  ${GREEN}*${NC}  %s\n" "$1"; }
warn()  { printf "  ${YELLOW}!${NC}  %s\n" "$1"; }
err()   { printf "  ${RED}x${NC}  %s\n" "$1"; }
step()  { printf "\n  ${CYAN}>${NC}  ${BOLD}%s${NC}\n" "$1"; }
die()   { err "$1"; exit 1; }

install_file() {
    local src="$1" dst="$2" mode="$3"
    install -m "$mode" "$src" "$dst" 2>/dev/null
}
install_dir_flat() {
    local src="$1" dst="$2" mode="$3" count=0
    [ -d "$src" ] || return 0
    mkdir -p "$dst"
    for f in "$src"/*; do
        [ -f "$f" ] || continue
        install -m "$mode" "$f" "$dst/$(basename "$f")"
        count=$((count + 1))
    done
    echo "$count"
}
install_tree() {
    local src="$1" dst="$2"
    [ -d "$src" ] || return 0
    mkdir -p "$dst"
    cp -a "$src/." "$dst/"
}

# =============================================================================
# Stage 1 — Pre-flight
# =============================================================================

pre_flight() {
    step "Pre-flight checks"
    check_root
    check_platform

    info "Platform: Telekom 5G Empfaenger (squashfs RO rootfs detected: $ROOTFS_RO)"
    info "Frontend src: $SRC_FRONTEND"
    info "Scripts src:  $SRC_SCRIPTS"
    info "Deps src:     $SRC_DEPS"

    [ -d "$SRC_FRONTEND" ] || die "Frontend source not found at $SRC_FRONTEND (did you run 'bun run build'?)"
    [ -d "$SRC_SCRIPTS" ] || die "Backend scripts not found at $SRC_SCRIPTS"

    info "Pre-flight passed"
}

# =============================================================================
# Stage 2 — Required tools sanity check
# =============================================================================

check_tools() {
    step "Verifying built-in substitutes for Entware packages"

    local missing=0
    have() {
        if command -v "$1" >/dev/null 2>&1; then
            info "$1 -> $(command -v "$1")"
        else
            warn "$1 not found"
            missing=$((missing + 1))
        fi
    }

    have wget                 # substitutes curl
    have openssl              # for cert ops if ever needed
    have /usr/bin/timeout     # substitutes coreutils-timeout
    have busybox              # provides httpd applet, awk, sed, etc.
    have systemctl            # systemd presence
    have date                 # for clock setting

    # busybox httpd specifically
    if /bin/busybox --list 2>/dev/null | tr ',' '\n' | grep -qx httpd; then
        info "busybox httpd applet available"
    else
        warn "busybox httpd applet missing — webserver setup will fail"
        missing=$((missing + 1))
    fi

    # wget HTTPS support
    if wget --version 2>&1 | head -3 | grep -q '+ssl'; then
        info "wget has TLS support"
    else
        warn "wget lacks TLS — OTA updates / GitHub fetches will fail"
    fi

    [ "$missing" -eq 0 ] || die "$missing required tool(s) missing — aborting"
}

# =============================================================================
# Stage 3 — Frontend (Next.js static export)
# =============================================================================

install_frontend() {
    step "Installing frontend"
    mkdir -p "$WWW_ROOT"
    rm -rf "$WWW_ROOT"/_next "$WWW_ROOT"/*.html "$WWW_ROOT"/*.ico 2>/dev/null || true
    cp -a "$SRC_FRONTEND"/. "$WWW_ROOT"/
    info "Frontend installed to $WWW_ROOT"
}

# =============================================================================
# Stage 4 — Backend (libs, daemons, CGI, jq binary)
# =============================================================================

install_backend() {
    step "Installing backend"

    # Shared shell libraries
    if [ -d "$SRC_SCRIPTS/usr/lib/qmanager" ]; then
        mkdir -p "$LIB_DIR"
        local c
        c=$(install_dir_flat "$SRC_SCRIPTS/usr/lib/qmanager" "$LIB_DIR" 644)
        info "$c libraries -> $LIB_DIR"
    fi

    # Daemons / utilities (originally would have been /usr/bin, now writable)
    if [ -d "$SRC_SCRIPTS/usr/bin" ]; then
        mkdir -p "$BIN_DIR"
        local c
        c=$(install_dir_flat "$SRC_SCRIPTS/usr/bin" "$BIN_DIR" 755)
        info "$c daemons/utilities -> $BIN_DIR"
    fi

    # AT-CLI and SMS tool (statically linked ARMv7l — no loader needed)
    if [ -f "$SRC_DEPS/atcli_smd11" ]; then
        install -m 755 "$SRC_DEPS/atcli_smd11" "$BIN_DIR/atcli_smd11"
        info "atcli_smd11 -> $BIN_DIR (static armv7l)"
    fi
    if [ -f "$SRC_DEPS/sms_tool" ]; then
        install -m 755 "$SRC_DEPS/sms_tool" "$BIN_DIR/sms_tool"
        info "sms_tool -> $BIN_DIR (static armv7l)"
    fi
    if [ -f "$SRC_DEPS/speedtest-armhf" ]; then
        install -m 755 "$SRC_DEPS/speedtest-armhf" "$BIN_DIR/speedtest"
        info "speedtest -> $BIN_DIR (Ookla 1.2.0 armhf, static)"
    fi

    # jq — REQUIRED. The bundled jq.ipk uses Entware's loader and will NOT
    # run on this device. A static armv7l jq must be supplied separately.
    # Acceptable sources, in order of preference:
    #   1. dependencies/jq-static-armv7l      (pre-bundled static jq)
    #   2. /usrdata/qmanager/bin/jq           (already present from prior install)
    if [ -f "$SRC_DEPS/jq-static-armv7l" ]; then
        install -m 755 "$SRC_DEPS/jq-static-armv7l" "$BIN_DIR/jq"
        info "jq -> $BIN_DIR (static armv7l)"
    elif [ -x "$BIN_DIR/jq" ]; then
        info "jq already installed at $BIN_DIR/jq — keeping"
    else
        warn "jq NOT installed. Provide a static armv7l jq at"
        warn "  $SRC_DEPS/jq-static-armv7l   (build instructions in README-TELEKOM.md)"
        warn "Many CGIs will fail until you add it."
    fi

    # CGI endpoints
    if [ -d "$SRC_SCRIPTS/www/cgi-bin/quecmanager" ]; then
        install_tree "$SRC_SCRIPTS/www/cgi-bin/quecmanager" "$CGI_DIR"
        find "$CGI_DIR" -name "*.sh" -type f -exec chmod 755 {} \;
        find "$CGI_DIR" -name "*.json" -exec chmod 644 {} \;
        info "$(find "$CGI_DIR" -name "*.sh" | wc -l | tr -d ' ') CGI scripts -> $CGI_DIR"
    fi

    # Telekom CGI overrides — overlay stubs for opkg-dependent features
    # (email alerts msmtp install, etc.) that can't work without Entware.
    # Each file under telekom-cgi-overrides/cgi-bin/quecmanager/... replaces
    # the same-named file at $WWW_ROOT/cgi-bin/quecmanager/... .
    if [ -d "$SRC_TELEKOM_OVERRIDES/cgi-bin/quecmanager" ]; then
        local override_count=0
        # find each override and copy it on top of the installed CGI
        for src in $(find "$SRC_TELEKOM_OVERRIDES/cgi-bin/quecmanager" -name "*.sh" -type f); do
            rel=${src#"$SRC_TELEKOM_OVERRIDES/cgi-bin/quecmanager/"}
            dst="$CGI_DIR/$rel"
            mkdir -p "$(dirname "$dst")"
            install -m 755 "$src" "$dst"
            override_count=$((override_count + 1))
            info "  stub: $rel"
        done
        info "$override_count CGI overrides installed (opkg-dependent features disabled)"
    fi

    # PATH augmentation for interactive shells and child processes
    mkdir -p /etc/profile.d
    cat > /etc/profile.d/qmanager.sh <<'PROFILE'
# Added by install_telekom_se.sh
# /usrdata/qmanager/bin is where QManager's bundled binaries live (jq,
# atcli_smd11, sms_tool, qmanager_* daemons) on Telekom firmware which
# does not have Entware.
case ":$PATH:" in
    *":/usrdata/qmanager/bin:"*) ;;
    *) export PATH="/usrdata/qmanager/bin:$PATH" ;;
esac
PROFILE
    chmod 644 /etc/profile.d/qmanager.sh
    info "PATH augmentation -> /etc/profile.d/qmanager.sh"

    # Path rewrites in installed CGIs / libs / daemons.
    # The upstream codebase hardcodes /usr/lib/qmanager, /usr/bin/qmanager_,
    # and /opt/bin/* (Entware layout). On the Telekom variant those paths
    # don't exist (RO rootfs, no Entware). We retarget them to our writable
    # /usrdata/qmanager/{lib,bin}/ layout. Same sed used on systemd units.
    local rewrite_count=0
    for d in "$CGI_DIR" "$LIB_DIR" "$BIN_DIR"; do
        [ -d "$d" ] || continue
        # Pick text files that reference any of the three patterns.
        # We don't filter by extension because CGI helpers in usr/bin/ have
        # no .sh suffix.
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            sed -i \
                -e 's|/usr/lib/qmanager/|/usrdata/qmanager/lib/|g' \
                -e 's|/usr/bin/qmanager_|/usrdata/qmanager/bin/qmanager_|g' \
                -e 's|/opt/bin/|/usrdata/qmanager/bin/|g' \
                "$f"
            rewrite_count=$((rewrite_count + 1))
        done <<EOF
$(grep -lrE '/usr/lib/qmanager|/usr/bin/qmanager_|/opt/bin/' "$d" 2>/dev/null)
EOF
    done
    info "$rewrite_count files path-rewritten"

    # Telekom firmware-specific: rewrite the AT channel from /dev/smd11 to
    # /dev/at_mdm0. The vendor processes (ltecommander PID, MCM_atcop_svc) hold
    # /dev/smd11 with ~12% per-call contention failure rate. /dev/at_mdm0 is
    # the modem's AT-modem channel, owned only by port_bridge which forwards
    # to /dev/at_usb0 — no contention for AT submission. Verified 15/15 calls
    # in 0s vs /dev/smd11's 7/8.
    #
    # Also add -p "$AT_DEVICE" to qcmd's atcli invocation so it actually uses
    # the configured device (upstream's qcmd has AT_DEVICE for sanity-check
    # only, doesn't pass it to atcli).
    if [ -f "$BIN_DIR/qcmd" ]; then
        sed -i \
            -e 's|^AT_DEVICE="/dev/smd11"|AT_DEVICE="/dev/at_mdm0"|' \
            -e 's|"\$AT_CLI" "\$COMMAND" 2>/dev/null|"\$AT_CLI" -p "\$AT_DEVICE" "\$COMMAND" 2>/dev/null|' \
            "$BIN_DIR/qcmd"
        if grep -q 'AT_DEVICE="/dev/at_mdm0"' "$BIN_DIR/qcmd"; then
            info "qcmd retargeted: /dev/smd11 -> /dev/at_mdm0 (Telekom variant)"
        else
            warn "qcmd retarget sed may have missed — verify manually"
        fi
    fi

    # Same /dev/smd11 -> /dev/at_mdm0 retarget for sms_tool callers. sms_tool
    # opens the AT device directly (not via qcmd / atcli_smd11) so it bypasses
    # the qcmd retarget above. If left on /dev/smd11 it hangs forever on
    # vendor contention and holds /tmp/qmanager_at.lock, which breaks every
    # other AT-using CGI ("modem_busy" errors).
    sms_patched=0
    for f in "$LIB_DIR/sms_alerts.sh" "$CGI_DIR/cellular/sms.sh"; do
        [ -f "$f" ] || continue
        sed -i \
            -e 's|_SA_AT_DEVICE="/dev/smd11"|_SA_AT_DEVICE="/dev/at_mdm0"|' \
            -e 's|^AT_DEVICE="/dev/smd11"|AT_DEVICE="/dev/at_mdm0"|' \
            "$f"
        sms_patched=$((sms_patched + 1))
    done
    [ "$sms_patched" -gt 0 ] && info "sms_tool callers retargeted: /dev/smd11 -> /dev/at_mdm0 ($sms_patched files)"

    # Tailscale CGI: detect-by-path -> detect-by-systemctl.
    # Upstream is_installed() hardcodes [ -f /lib/systemd/system/tailscaled.service ]
    # which never matches on this layout (our unit is at /etc/systemd/system/
    # because /lib is on RO squashfs). Replace with a path-agnostic check that
    # asks systemd itself, plus dynamic UNIT_DIR/WANTS_DIR resolution.
    ts_cgi="$CGI_DIR/vpn/tailscale.sh"
    if [ -f "$ts_cgi" ]; then
        # Replace the hardcoded WANTS_DIR + UNIT_DIR block with a dynamic one
        if grep -q '^WANTS_DIR="/lib/systemd/system/multi-user.target.wants"$' "$ts_cgi"; then
            sed -i \
                -e '/^WANTS_DIR="\/lib\/systemd\/system\/multi-user.target.wants"$/c\
_TS_FRAG=$(systemctl show -p FragmentPath --value tailscaled 2>/dev/null)\
UNIT_DIR=${_TS_FRAG:+$(dirname "$_TS_FRAG")}\
UNIT_DIR=${UNIT_DIR:-/lib/systemd/system}\
WANTS_DIR="$UNIT_DIR/multi-user.target.wants"' \
                -e '/^UNIT_DIR="\/lib\/systemd\/system"$/d' \
                "$ts_cgi"
        fi
        # Replace is_installed body to use systemctl, not a hardcoded /lib path
        sed -i 's|\[ -f /lib/systemd/system/tailscaled.service \] && \[ -d "$TAILSCALE_DIR" \]|[ -d "$TAILSCALE_DIR" ] \&\& [ -x "$TAILSCALED_BIN" ] \&\& systemctl cat tailscaled --no-pager >/dev/null 2>\&1|' "$ts_cgi"
        info "vpn/tailscale.sh: is_installed retargeted to systemctl-cat detection"
    fi
}

# =============================================================================
# Stage 5 — Web server (busybox httpd, replacing lighttpd)
# =============================================================================

install_webserver() {
    step "Installing web server (busybox httpd)"

    # Minimal config file — busybox httpd's docroot, port, optional auth file
    # are all CLI flags; this conf is mostly for documentation + MIME types.
    cat > "$HTTPD_CONF" <<'HTTPD'
# busybox httpd config for QManager.
# Most flags are passed on the systemd ExecStart line; this file is loaded
# via -c to define MIME types and small bits.

# MIME types (busybox httpd format: .ext\tmime/type)
.html	text/html
.css	text/css
.js	application/javascript
.json	application/json
.svg	image/svg+xml
.png	image/png
.jpg	image/jpeg
.ico	image/x-icon
.woff	font/woff
.woff2	font/woff2
.txt	text/plain

# Allow access from any source (firewall/Tailscale gates exposure)
A:*
HTTPD
    chmod 644 "$HTTPD_CONF"
    info "$HTTPD_CONF written"

    # systemd unit — runs busybox httpd on :9090
    # Port 9090 chosen because Arcadyan stock httpd owns :80 and
    # legacy simpleadmin used :8080.
    cat > "$SYSTEMD_DIR/qmanager_httpd.service" <<'UNIT'
[Unit]
Description=QManager httpd (busybox)
Documentation=https://github.com/dr-dolomite/QManager-RM520N
After=network.target

[Service]
Type=simple
# PATH must include /usrdata/qmanager/bin so CGIs can find `jq`, `atcli_smd11`,
# `sms_tool`, and the qmanager_* daemons without absolute references.
Environment=PATH=/usrdata/qmanager/bin:/usr/sbin:/usr/bin:/sbin:/bin
# Run as root so CGI scripts have full system access without sudo.
# Access surface is restricted by the modem's iptables (LAN-only) and
# by Tailscale (which is the recommended access path).
ExecStart=/bin/busybox httpd -f -h /usrdata/qmanager/www -p 9090 -c /usrdata/qmanager/httpd.conf
Restart=on-failure
RestartSec=5
StandardOutput=null
StandardError=null

[Install]
WantedBy=multi-user.target
UNIT
    chmod 644 "$SYSTEMD_DIR/qmanager_httpd.service"
    info "systemd unit -> $SYSTEMD_DIR/qmanager_httpd.service"
}

# =============================================================================
# Stage 6 — QManager systemd units (poller, firewall, ping, etc.)
# =============================================================================

install_systemd_units() {
    step "Installing QManager systemd units"

    local src_systemd="$SRC_SCRIPTS/etc/systemd/system"
    [ -d "$src_systemd" ] || { warn "no systemd units in source tree"; return; }

    local installed=0 skipped=0
    for unit in "$src_systemd"/qmanager-*.service; do
        [ -f "$unit" ] || continue
        local name; name=$(basename "$unit")
        # Skip features that need Entware-only deps (discord, ttyd console)
        case "$name" in
            qmanager-discord.service) skipped=$((skipped + 1)); continue ;;
            qmanager-console.service) skipped=$((skipped + 1)); continue ;;
        esac
        # Rewrite paths that point at /opt or /usr/bin/<qmanager-binary>:
        # the QManager unit files assume Entware install layout. We retarget
        # to /usrdata/qmanager/bin/.
        sed -e 's|/usr/bin/qmanager_|/usrdata/qmanager/bin/qmanager_|g' \
            -e 's|/opt/bin/|/usrdata/qmanager/bin/|g' \
            "$unit" > "$SYSTEMD_DIR/$name"
        chmod 644 "$SYSTEMD_DIR/$name"
        installed=$((installed + 1))
    done
    info "$installed qmanager-*.service units installed (skipped: $skipped Entware-only)"

    # Tailscale safety: do NOT touch an existing tailscaled.service.
    # Either a manually-deployed unit (this device's current state) or a
    # previously-installed QManager copy. The unit we ship lives in
    # $LIB_DIR for the UI to copy into place ONLY if the user explicitly
    # clicks "Install Tailscale", which is gated by qmanager_tailscale_mgr.
    for f in tailscaled.service tailscaled.defaults; do
        local src="$src_systemd/$f"
        [ -f "$src" ] || continue
        install -m 644 "$src" "$LIB_DIR/$f"
        info "staged $f -> $LIB_DIR (not activated)"
    done

    if systemctl cat tailscaled --no-pager >/dev/null 2>&1; then
        info "existing tailscaled unit detected — left untouched"
    fi
}

# =============================================================================
# Stage 7 — Enable + start the bits we own
# =============================================================================

enable_and_start() {
    step "Enabling QManager services"

    systemctl daemon-reload
    info "daemon-reload done"

    # The webserver
    systemctl enable qmanager_httpd.service >/dev/null 2>&1 || true
    info "qmanager_httpd.service enabled"

    # QManager's own daemons
    for unit in "$SYSTEMD_DIR"/qmanager-*.service; do
        [ -f "$unit" ] || continue
        local name; name=$(basename "$unit")
        systemctl enable "$name" >/dev/null 2>&1 || warn "could not enable $name"
    done

    if [ "${1:-}" = "--skip-restart" ]; then
        warn "--skip-restart: not starting services. Reboot or run:"
        warn "    systemctl start qmanager_httpd qmanager-*"
        return
    fi

    step "Starting services"
    systemctl start qmanager_httpd.service || warn "qmanager_httpd failed to start"
    for unit in "$SYSTEMD_DIR"/qmanager-*.service; do
        [ -f "$unit" ] || continue
        systemctl start "$(basename "$unit")" 2>/dev/null || true
    done
    sleep 2

    # Quick health check
    if systemctl is-active qmanager_httpd >/dev/null 2>&1; then
        info "qmanager_httpd running on :9090"
        info "Access via Tailscale:  http://de-telekom-empfaenger:9090/"
    else
        warn "qmanager_httpd is not active — check 'systemctl status qmanager_httpd'"
    fi
}

# =============================================================================
# Stage 8 — Summary
# =============================================================================

summary() {
    step "Install complete"
    info "Frontend: $WWW_ROOT"
    info "CGI:      $CGI_DIR"
    info "Bin:      $BIN_DIR"
    info "Lib:      $LIB_DIR"
    info "Units:    $SYSTEMD_DIR/qmanager_httpd.service + qmanager-*.service"
    info "Config:   $HTTPD_CONF"
    echo
    info "To verify:"
    echo "    systemctl status qmanager_httpd"
    echo "    curl -s http://localhost:9090/cgi-bin/quecmanager/<endpoint>"
    echo "    tailscale ssh root@de-telekom-empfaenger -- systemctl status qmanager_httpd"
    echo
    if [ ! -x "$BIN_DIR/jq" ]; then
        warn "REMINDER: jq is missing. Build a static armv7l binary (see README-TELEKOM.md)"
        warn "and drop it at $BIN_DIR/jq before expecting most CGI endpoints to work."
    fi
}

# =============================================================================
# main
# =============================================================================

main() {
    pre_flight
    check_tools
    install_frontend
    install_backend
    install_webserver
    install_systemd_units
    enable_and_start "$@"
    summary
}

main "$@"
