# QManager — Telekom 5G Empfänger variant (no Entware)

This branch (`telekom-no-entware`) is a port of [QManager-RM520N](https://github.com/dr-dolomite/QManager-RM520N) to the **Telekom 5G Empfänger** — the Arcadyan-customized RG520NEUDB hardware that Telekom ships in Germany.

The upstream installer assumes a stock RM520N-GL with a writable rootfs and bootstraps Entware. That assumption breaks on Telekom's variant because:

1. **`/` is `squashfs ro`** — cannot be remounted RW, so the Entware mount point (`/opt`) cannot be created on the rootfs.
2. **The A/B firmware design** means even if we could mount onto `/opt`, the change would not survive an OTA slot swap.

This variant skips Entware entirely and uses only what's already on the firmware.

---

## Substitution map

| Upstream Entware dep | Replaced with | Source |
|---|---|---|
| `entware-opt` | *(skipped — no Entware)* | — |
| `curl` | `/usr/bin/wget` (GNU 1.20.3, `+https +ssl/gnutls`) | firmware |
| `lighttpd` + `mod_cgi` | `/bin/busybox httpd -f -h … -p 9090 -c …` | firmware |
| `lighttpd-mod-openssl` | *(skipped — Tailscale provides encryption)* | — |
| `lighttpd-mod-redirect` | *(skipped — no HTTP→HTTPS redirect needed)* | — |
| `lighttpd-mod-proxy` | *(skipped — `/console` ttyd feature is optional)* | — |
| `sudo` | *(skipped — httpd runs as root; `_SUDO=""` branch in `platform.sh`)* | — |
| `coreutils-timeout` | `/usr/bin/timeout` | firmware |
| `jq` | bundled `dependencies/jq-static-armv7l` | official jq 1.7.1 armhf static |
| `dropbear` | *(skipped — Tailscale SSH is the only remote access path)* | — |

Optional QManager features that need Entware-only packages are disabled in this variant:
- **Email Alerts** (`msmtp`) — would need static armv7l msmtp
- **Discord bot** — Go binary, Entware-independent in principle, but disabled in the unit list
- **Web console** (`ttyd` via lighttpd `mod_proxy`) — disabled
- **Built-in dropbear** SSH server — disabled; use Tailscale SSH

---

## Path layout (different from upstream)

| Item | Upstream RM520N | This variant |
|---|---|---|
| Systemd units | `/lib/systemd/system/` | `/etc/systemd/system/` (writable on `ubi2_0`, slot-independent) |
| Binaries | `/usr/bin/` | `/usrdata/qmanager/bin/` |
| Libraries | `/usr/lib/qmanager/` | `/usrdata/qmanager/lib/` |
| Web root | `/usrdata/qmanager/www/` | unchanged |
| CGI scripts | `/usrdata/qmanager/www/cgi-bin/quecmanager/` | unchanged |
| Web server port | `:80` + `:443` (lighttpd) | `:9090` (HTTP only) |
| PATH augmentation | `ln -s /opt/bin/curl /usr/bin/curl` | `/etc/profile.d/qmanager.sh` adds `/usrdata/qmanager/bin` |

`/etc` is mounted from `/dev/ubi2_0` on this firmware — same writable UBI volume that backs `/usrdata`. Files in either path persist across reboot **and** across A/B firmware slot swaps.

---

## Build + install workflow

### One-time build (on a Mac or Linux box with bun + Go)

```sh
git clone https://github.com/idstein/QManager-RM520N-telekom.git
cd QManager-RM520N-telekom
git checkout telekom-no-entware

# Build the Next.js frontend → ./out/
bun install
bun run build

# Package
bash build.sh    # produces qmanager-build/qmanager.tar.gz
```

### Deploy to the modem (no GitHub, no Entware, all over Tailscale)

```sh
# From the Mac:
tailscale file cp qmanager-build/qmanager.tar.gz de-telekom-empfaenger:

# From the modem (via tailscale ssh):
tailscale ssh root@de-telekom-empfaenger
tailscale file get -conflict=overwrite /tmp/
tar xzf /tmp/qmanager.tar.gz -C /tmp/
bash /tmp/qmanager_install/install_telekom_se.sh
```

---

## `jq` — bundled

QManager's CGI scripts depend on `jq` for JSON parsing. The upstream `dependencies/jq.ipk` is an Entware package — its `jq` binary is dynamically linked against Entware's loader (`/opt/lib/ld-linux.so.3`) and **will not run on this device** without Entware.

This variant bundles **`dependencies/jq-static-armv7l`** — the official jq 1.7.1 `jq-linux-armhf` release, which is a fully statically-linked ARM EABI5 binary (~1.3 MB):

```
$ file dependencies/jq-static-armv7l
ELF 32-bit LSB executable, ARM, EABI5 version 1 (SYSV), statically linked, …
```

Verified working on the Telekom 5G Empfänger:

```
$ /tmp/jq-linux-armhf --version
jq-1.7.1
$ echo '{"hello":"world","n":[1,2,3]}' | jq '.n | map(. * 2)'
[2, 4, 6]
```

If you ever need to refresh it:

```sh
curl -fsSL -o dependencies/jq-static-armv7l \
  https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-armhf
# verify still statically linked:
file dependencies/jq-static-armv7l
```

The installer picks it up automatically and copies it to `/usrdata/qmanager/bin/jq` with mode 755.

---

## Tailscale handling

If the modem **already has Tailscale running** (typical state for this device — its only remote-access path), the installer:

- **Does not download Tailscale.**
- **Does not modify** `/etc/systemd/system/tailscaled.service`.
- **Does not stop or restart `tailscaled`.**
- Stages a copy of QManager's preferred `tailscaled.service` into `/usrdata/qmanager/lib/` for the UI's "Install Tailscale" button — which is itself gated by `qmanager_tailscale_mgr`'s idempotency check (it refuses to install over an existing healthy daemon unless `--force` is given).

In other words: the existing tailnet session survives the install. SSH access is not interrupted.

---

## What's NOT in this variant yet

This is a `dev` draft. Known gaps:

1. **jq sourcing** — `dependencies/jq-static-armv7l` must be supplied (see above).
2. **OTA upgrade** — `qmanager-settings/check_package_info.sh` etc. hit `opkg list-installed` and assume Entware. Will fail; would need a Telekom-specific OTA scheme. (For now: re-build + push tarball manually.)
3. **Email alerts (msmtp)** — disabled. Could be revived with a static msmtp.
4. **Discord bot** — unit installation is skipped.
5. **Web console (`/console` ttyd)** — disabled. Use Tailscale SSH directly.
6. **Firewall unit (`qmanager-firewall.service`)** — installed as-is from the upstream tree. Its rules assume lighttpd on `:80`/`:443`. Review before enabling — may need port-rewrite to `:9090`.

---

## Recovery if `install_telekom_se.sh` half-installs

The installer is **NOT** fully idempotent yet. If it fails partway, you can either:

```sh
# Remove everything QManager-related:
systemctl stop qmanager_httpd qmanager-* 2>/dev/null
systemctl disable qmanager_httpd qmanager-* 2>/dev/null
rm -f /etc/systemd/system/qmanager_httpd.service
rm -f /etc/systemd/system/qmanager-*.service
rm -f /etc/systemd/system/multi-user.target.wants/qmanager*
rm -rf /usrdata/qmanager
rm -f /etc/profile.d/qmanager.sh
systemctl daemon-reload
```

Tailscale is **not** touched by the install or this cleanup.

---

## Upstream contribution path

The substitutions in this variant are tightly scoped and should be reasonable to merge upstream:

1. Detect rootfs writability (`touch /usr/.test`) at install time.
2. Branch SYSTEMD_DIR / BIN_DIR / LIB_DIR / package-source decisions on that.
3. Allow `--no-entware` flag to force the busybox path on hardware where Entware would otherwise be installed.

A clean PR could express this as ~50 lines of conditional in `install_rm520n.sh` plus the alternate webserver unit. The current `install_telekom_se.sh` is a parallel-file approach for ease of review during early development.
