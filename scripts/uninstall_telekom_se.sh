#!/bin/bash
# =============================================================================
# QManager Uninstall — Telekom 5G Empfaenger variant (no Entware)
# =============================================================================
# Symmetric counterpart to install_telekom_se.sh. Removes everything that
# installer created, in reverse order. Preserves:
#
#   * /usrdata/tailscale/             (Tailscale binaries + state — our SSH path)
#   * /etc/systemd/system/tailscaled.service        (active tailscaled unit)
#   * /etc/systemd/system/multi-user.target.wants/tailscaled.service
#   * /usrdata/tailscale/systemd/     (QManager-staged tailscale unit, harmless)
#   * /etc/qmanager/                  (config + passwords) unless --purge
#
# This uninstaller does NOT touch Entware (there is no Entware on this
# variant by design).
#
# Usage:  bash uninstall_telekom_se.sh [--purge] [--force] [--help]
# =============================================================================

set -e

# --- Colors & icons (mirror upstream uninstall style) -------------------------

if [ -t 1 ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    BLUE='\033[0;34m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; BOLD=''; DIM=''; NC=''
fi
ICO_OK='✓'; ICO_WARN='⚠'; ICO_ERR='✗'; ICO_STEP='▶'

LOG_FILE="/tmp/qmanager_telekom_uninstall.log"

_log_raw() { printf "%s\n" "$1" >> "$LOG_FILE" 2>/dev/null || true; }

info()  { printf "    ${GREEN}${ICO_OK}${NC}  %s\n" "$1"; _log_raw "[INFO]  $1"; }
warn()  { printf "    ${YELLOW}${ICO_WARN}${NC}  %s\n" "$1"; _log_raw "[WARN]  $1"; }
error() { printf "    ${RED}${ICO_ERR}${NC}  %s\n" "$1"; _log_raw "[ERROR] $1"; }
die()   { error "$1"; exit 1; }

CURRENT_STEP=0; TOTAL_STEPS=7
step() {
    CURRENT_STEP=$(( CURRENT_STEP + 1 ))
    printf "\n  ${DIM}[Step %d/%d]${NC}\n" "$CURRENT_STEP" "$TOTAL_STEPS"
    printf "  ${BLUE}${BOLD}${ICO_STEP}${NC}${BOLD} %s${NC}\n" "$1"
    _log_raw ""
    _log_raw "=== Step ${CURRENT_STEP}/${TOTAL_STEPS}: $1 ==="
}

# --- Paths (must match install_telekom_se.sh) --------------------------------

QMANAGER_ROOT="/usrdata/qmanager"
SYSTEMD_DIR="/etc/systemd/system"
WANTS_DIR="/etc/systemd/system/multi-user.target.wants"
CONF_DIR="/etc/qmanager"
PROFILE_D_SNIPPET="/etc/profile.d/qmanager.sh"

# Tailscale paths — explicitly protected
TAILSCALE_DIR="/usrdata/tailscale"
TAILSCALED_UNIT="$SYSTEMD_DIR/tailscaled.service"

# --- CLI parsing -------------------------------------------------------------

PURGE=0; FORCE=0

usage() {
    cat <<USAGE
QManager Uninstall (Telekom 5G Empfaenger variant)

Usage: bash uninstall_telekom_se.sh [OPTIONS]

Options:
  --purge       Also remove /etc/qmanager/ (config, passwords)
  --force       Skip interactive confirmation
  --help, -h    Show this help

Always preserved:
  - /usrdata/tailscale/                  (Tailscale binaries + state)
  - /etc/systemd/system/tailscaled.service
  - /etc/systemd/system/multi-user.target.wants/tailscaled.service

Log: $LOG_FILE
USAGE
}

for arg in "$@"; do
    case "$arg" in
        --purge)    PURGE=1 ;;
        --force)    FORCE=1 ;;
        --help|-h)  usage; exit 0 ;;
        *)          warn "Unknown argument: $arg" ;;
    esac
done

[ "$(id -u)" -eq 0 ] || die "must be run as root"

printf "QManager Telekom Uninstall — %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" > "$LOG_FILE"
printf "Args: %s\n\n" "$*" >> "$LOG_FILE"

# Confirmation
if [ "$FORCE" -ne 1 ]; then
    printf "\n  ${YELLOW}This will remove QManager from this device.${NC}\n"
    if [ "$PURGE" -eq 1 ]; then
        printf "  ${YELLOW}--purge: $CONF_DIR will also be deleted.${NC}\n"
    fi
    printf "  Tailscale will NOT be touched.\n\n"
    printf "  Proceed? [y/N] "
    read -r ans
    case "$ans" in
        y|Y|yes|YES) ;;
        *) printf "\n  Aborted.\n\n"; exit 0 ;;
    esac
fi

# =============================================================================
# Step 1 — Stop services (do NOT touch tailscaled)
# =============================================================================

step "Stopping QManager services"

# Collect qmanager-* + qmanager_httpd, deliberately exclude tailscaled and
# anything tailscale-related.
units_to_stop=""
for u in "$SYSTEMD_DIR"/qmanager_httpd.service "$SYSTEMD_DIR"/qmanager-*.service; do
    [ -f "$u" ] || continue
    name=$(basename "$u")
    case "$name" in
        tailscaled.service) continue ;;
    esac
    units_to_stop="$units_to_stop $name"
done

if [ -n "$units_to_stop" ]; then
    systemctl stop $units_to_stop 2>/dev/null || true
    info "stopped:$units_to_stop"
else
    warn "no QManager units found to stop"
fi

# =============================================================================
# Step 2 — Disable + remove wants symlinks
# =============================================================================

step "Disabling units (removing wants symlinks)"

for u in $units_to_stop; do
    systemctl disable "$u" 2>/dev/null || true
done

# Belt-and-suspenders: directly remove any leftover symlinks under wants/
if [ -d "$WANTS_DIR" ]; then
    rm -f "$WANTS_DIR"/qmanager_httpd.service
    rm -f "$WANTS_DIR"/qmanager-*.service
fi
info "wants symlinks removed"

# =============================================================================
# Step 3 — Remove unit files from /etc/systemd/system
# =============================================================================

step "Removing unit files"

removed=0
for u in "$SYSTEMD_DIR"/qmanager_httpd.service "$SYSTEMD_DIR"/qmanager-*.service; do
    [ -f "$u" ] || continue
    case "$(basename "$u")" in
        tailscaled.service) continue ;;
    esac
    rm -f "$u" && removed=$((removed + 1))
done
info "removed $removed unit files from $SYSTEMD_DIR"

# Explicit guard: confirm tailscaled.service was not touched
if [ -f "$TAILSCALED_UNIT" ]; then
    info "tailscaled.service intact at $TAILSCALED_UNIT"
else
    warn "tailscaled.service is missing from $SYSTEMD_DIR — was it not installed?"
fi

# =============================================================================
# Step 4 — Remove PATH augmentation
# =============================================================================

step "Removing /etc/profile.d/qmanager.sh"

if [ -f "$PROFILE_D_SNIPPET" ]; then
    rm -f "$PROFILE_D_SNIPPET"
    info "removed $PROFILE_D_SNIPPET"
else
    warn "$PROFILE_D_SNIPPET not present"
fi

# =============================================================================
# Step 5 — Remove /usrdata/qmanager
# =============================================================================

step "Removing $QMANAGER_ROOT"

if [ -d "$QMANAGER_ROOT" ]; then
    # Sanity: $TAILSCALE_DIR is /usrdata/tailscale, NOT under /usrdata/qmanager,
    # so this rm cannot touch it. Still defensive: a relative-path bug would
    # be very bad for a script accessed only over the Tailscale daemon we are
    # supposed to preserve.
    case "$QMANAGER_ROOT" in
        /usrdata/qmanager) ;;
        *) die "QMANAGER_ROOT looks unsafe: $QMANAGER_ROOT — aborting" ;;
    esac
    rm -rf "$QMANAGER_ROOT"
    info "removed $QMANAGER_ROOT (including bin/ lib/ www/ httpd.conf)"
else
    warn "$QMANAGER_ROOT not present"
fi

# =============================================================================
# Step 6 — Optionally remove /etc/qmanager (config)
# =============================================================================

step "Configuration directory"

if [ "$PURGE" -eq 1 ]; then
    if [ -d "$CONF_DIR" ]; then
        rm -rf "$CONF_DIR"
        info "purged $CONF_DIR"
    else
        info "$CONF_DIR already absent"
    fi
else
    if [ -d "$CONF_DIR" ]; then
        info "preserved $CONF_DIR (pass --purge to remove)"
    fi
fi

# =============================================================================
# Step 7 — daemon-reload + verify
# =============================================================================

step "Reload systemd + verify Tailscale survived"

systemctl daemon-reload || warn "systemctl daemon-reload failed"
info "systemctl daemon-reload done"

# Tailscale verification — exit non-zero if it died
ts_active=$(systemctl is-active tailscaled 2>&1 || true)
case "$ts_active" in
    active)
        info "tailscaled is still active — Tailscale SSH path is intact"
        ;;
    *)
        error "tailscaled is NOT active (state: $ts_active)"
        error "This is unexpected. Investigate with: systemctl status tailscaled"
        ;;
esac

# --- Summary -----------------------------------------------------------------

printf "\n  ${GREEN}${BOLD}QManager removed.${NC}\n"
printf "  Log: %s\n\n" "$LOG_FILE"

if [ "$PURGE" -ne 1 ] && [ -d "$CONF_DIR" ]; then
    printf "  ${DIM}Config preserved at $CONF_DIR.${NC}\n"
    printf "  ${DIM}Re-run with --purge to remove it.${NC}\n\n"
fi
