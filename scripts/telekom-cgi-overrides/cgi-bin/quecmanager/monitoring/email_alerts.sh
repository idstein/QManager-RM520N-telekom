#!/bin/sh
. /usr/lib/qmanager/cgi_base.sh
# =============================================================================
# email_alerts.sh — STUB for Telekom 5G Empfaenger variant
# =============================================================================
# The full email_alerts.sh tries to install `msmtp` via opkg. On Telekom
# hardware there's no Entware (no /opt mountpoint on the squashfs rootfs),
# so this returns a clear "not supported" response instead of failing
# halfway through.
#
# To re-enable email alerts you would need:
#   1. A static armv7l msmtp + ca-certificates bundled under
#      /usrdata/qmanager/bin/ + /etc/ssl/certs/
#   2. Replace this stub by removing /usrdata/qmanager/www/cgi-bin/quecmanager/
#      monitoring/email_alerts.sh and re-installing the upstream file.
# =============================================================================

qlog_init "cgi_email_alerts_stub"
cgi_headers
cgi_handle_options

cat <<'EOF'
{
  "success": false,
  "status": "feature_disabled",
  "platform": "telekom-5g-empfaenger",
  "message": "Email alerts (msmtp) are disabled on this platform. The default install path needs Entware, which cannot be bootstrapped on the read-only squashfs rootfs of this firmware. See README-TELEKOM.md for details.",
  "configured": false,
  "enabled": false
}
EOF
exit 0
