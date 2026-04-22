# owl.red-openwrt

Full-stack OpenWrt provisioning for a D-Link DIR-885L — configures networks, WiFi, firewall zones, DHCP/DNS, LEDs, a custom OpenNDS captive portal, and optional HTTPS via Let's Encrypt. One script, one `.env`, factory reset to fully configured.

The deploy script is named per router model (`deploy-dir885l.sh`) because it contains hardware-specific logic (DSA switch layout, LED names, radio detection). Config templates in `config/` are model-agnostic and reusable if you add more routers later.

Themed with [Catppuccin Mocha](https://github.com/catppuccin/catppuccin) colors. The captive portal is satirical psyop-themed. The infrastructure is not.

---

## Network Architecture

```
                    ┌──────────────┐
                    │   Internet   │
                    └──────┬───────┘
                           │ WAN (DHCP)
                    ┌──────┴───────┐
                    │  DIR-885L    │
                    │  OpenWrt     │
                    │  WAP1        │
                    └──┬───┬───┬───┘
                       │   │   │
          ┌────────────┘   │   └────────────┐
          │                │                │
    ┌─────┴─────┐   ┌─────┴─────┐   ┌──────┴─────┐
    │   LAN     │   │   Guest   │   │    IoT     │
    │ br-lan    │   │ br-guest  │   │  br-iot    │
    │10.10.10/24│   │10.10.30/24│   │10.10.50/24 │
    │ lan1-4    │   │ WiFi only │   │ WiFi only  │
    │ WiFi 2G+5G│   │ WiFi 2G+5G│   │ WiFi 2G    │
    └───────────┘   └───────────┘   └────────────┘

    wap1.owl.red     guest.owl.red
    Luci :80/:443    Portal :443
```

### Zones & Firewall Policy

| Zone | Internet | Cross-zone | Notes |
|------|----------|------------|-------|
| **LAN** | ✓ | Can reach IoT | Full trust, all 4 physical ports + WiFi |
| **Guest** | ✓ | Can reach IoT | Client isolation ON, captive portal |
| **IoT** | ✓ | Cannot initiate to LAN/Guest | 2.4GHz only, devices talk to each other |
| **WAN** | — | Inbound rejected | Masquerading enabled |

---

## What Gets Deployed

### UCI Config Templates (config/ → /etc/config/)

| File | Deploys To | Placeholders | Purpose |
|------|-----------|-------------|---------|
| `config/network` | `/etc/config/network` | — | Interfaces: loopback, br-lan, wan, br-guest, br-iot |
| `config/wireless` | `/etc/config/wireless` | `%%RADIO*_PATH%%`, `%%*_SSID%%`, `%%*_WIFI_KEY%%`, `%%COUNTRY_CODE%%` | Radios + 5 SSIDs |
| `config/firewall` | `/etc/config/firewall` | — | 4 zones, forwarding, traffic rules, OpenNDS include |
| `config/dhcp` | `/etc/config/dhcp` | `%%DOMAIN%%` | dnsmasq, 3 DHCP pools, local DNS |
| `config/system` | `/etc/config/system` | `%%HOSTNAME%%`, `%%TZ_OFFSET%%`, `%%TIMEZONE%%` | Hostname, NTP, DIR-885L LEDs |
| `config/uhttpd` | `/etc/config/uhttpd` | — | Luci on LAN only, guest HTTPS instance |
| `config/opennds` | `/etc/config/opennds` | — | OpenNDS: br-guest, ThemeSpec, status page |

### Portal Files

| File | Deploys To | Purpose |
|------|-----------|---------|
| `themespec/theme_owlred.sh` | `/usr/lib/opennds/theme_owlred.sh` | ThemeSpec: splash, privacy, security, landing pages |
| `themespec/client_params_owlred.sh` | `/usr/lib/opennds/client_params_owlred.sh` | HTTP status page script |
| `htdocs/splash.css` | `/etc/opennds/htdocs/splash.css` | Catppuccin Mocha CSS |
| `htdocs/cgi-bin/status` | `/www-guest/cgi-bin/status` | HTTPS status page CGI |
| `htdocs/index.html` | `/www-guest/index.html` | HTTPS redirect to CGI |
| `portal/*` | `/etc/opennds/htdocs/images/` | Portal images |

---

## Repository Structure

```
owl.red-openwrt/
├── deploy-dir885l.sh            DIR-885L provisioning script (bash, ~750 lines)
├── README.md
├── .env.example                 Environment template (all variables documented)
├── .gitignore
├── .gitattributes               Enforce LF line endings
│
├── config/                      UCI config templates (%%VAR%% placeholders)
│   ├── network
│   ├── wireless
│   ├── firewall
│   ├── dhcp
│   ├── system
│   ├── uhttpd
│   └── opennds
│
├── portal/                      Portal images
│   ├── psyop-cat.png
│   ├── ourinformation.jpg
│   ├── alwayswatching.jpg
│   ├── cultsecurity.jpg
│   └── welcome-owl.jpg
│
├── htdocs/                      Web content
│   ├── splash.css
│   ├── index.html
│   └── cgi-bin/
│       └── status
│
└── themespec/                   OpenNDS ThemeSpec scripts
    ├── theme_owlred.sh
    └── client_params_owlred.sh
```

---

## How to Use

### Prerequisites

**On the router:**
- OpenWrt 25.x installed on D-Link DIR-885L
- Root password set
- Basic network connectivity (WAN plugged in)

**On your machine:**
- bash 4+, ssh, scp
- sshpass (for password auth): `sudo apt install sshpass`

### 1. Clone and configure

```bash
git clone <repo-url> owl.red-openwrt
cd owl.red-openwrt
cp .env.example .env
```

Edit `.env` with your values:

```bash
# Router connection
ROUTER_IP=192.168.1.1          # Factory default, or current IP
ROUTER_USER=root
ROUTER_PASS=your-password

# System
HOSTNAME=WAP1
DOMAIN=owl.red
TIMEZONE=America/Edmonton
TZ_OFFSET=MST7MDT,M3.2.0,M11.1.0
COUNTRY_CODE=CA

# WiFi
LAN_SSID=Silence of the LANs
LAN_WIFI_KEY=your-lan-password
GUEST_SSID=Router? I Barely Know Her
GUEST_WIFI_KEY=your-guest-password
IOT_SSID=robots only
IOT_WIFI_KEY=your-iot-password

# HTTPS (optional — omit to skip)
CF_TOKEN=your-cloudflare-api-token
CF_ACCOUNT_ID=your-account-id
CF_ZONE_ID=your-zone-id
```

### 2. Deploy

```bash
chmod +x deploy-dir885l.sh
./deploy-dir885l.sh
```

> **Why the router name in the script?** The deploy script contains hardware-specific
> logic (DSA switch config, LED mappings, radio paths). If you add a different router
> model later, create a separate `deploy-<model>.sh` that shares the same config
> templates but handles model-specific differences.

### 3. What happens

The script runs 9 phases:

1. **Init** — Loads `.env`, validates all required variables, checks local files
2. **Connect & Discover** — Tests SSH, reads radio hardware paths, detects IP changes
3. **Packages** — Installs OpenNDS (and ACME if HTTPS enabled)
4. **Backup** — Backs up all `/etc/config/` files to `/tmp/owlred-backup-<timestamp>/`
5. **Template & Deploy** — Substitutes `%%VARIABLES%%` in config templates, SCPs to router
6. **Portal Files** — Deploys ThemeSpec, CSS, images, CGI, symlinks
7. **Apply** — Restarts services (handles IP change with reboot + reconnect)
8. **HTTPS** — Issues Let's Encrypt certs via Cloudflare DNS-01 (if configured)
9. **Verify** — Checks all services, prints summary with URLs and rollback instructions

**If the router IP changes** (e.g., factory 192.168.1.1 → 10.10.10.1), the script automatically reboots the router and reconnects at the new IP.

---

## HTTPS (Optional)

HTTPS requires a domain on Cloudflare. The script issues certs for:
- `guest.<DOMAIN>` — Guest portal HTTPS status page
- `<hostname>.<DOMAIN>` — Luci admin HTTPS

**How it works:**
- Uses `acme.sh` with Cloudflare DNS-01 validation (no public HTTP required)
- Issues EC-256 certificates from Let's Encrypt
- Configures separate uhttpd instances with the certs
- Sets up weekly cron renewal

**Important:** The captive portal splash page is always HTTP — operating systems send HTTP requests for captive portal detection, and OpenNDS intercepts those via iptables. HTTPS only applies to the post-auth status page and Luci admin.

If `CF_TOKEN` is not set in `.env`, all HTTPS setup is skipped.

---

## WiFi Networks

| SSID | Band | Zone | Client Isolation | Purpose |
|------|------|------|-----------------|---------|
| Silence of the LANs | 2.4GHz + 5GHz | LAN | No | Trusted network |
| Router? I Barely Know Her | 2.4GHz + 5GHz | Guest | Yes | Captive portal, internet access |
| robots only | 2.4GHz only | IoT | No | IoT devices, internet access |

---

## LED Configuration (DIR-885L)

| LED | Behavior | Meaning |
|-----|----------|---------|
| Power white | Always on | System powered |
| Power amber | Heartbeat | System alive (stops = frozen) |
| WAN white | Link | WAN cable connected |
| WAN amber | Activity | WAN tx/rx traffic |
| 2.4GHz white | phy0tpt | Any 2.4GHz radio activity |
| 5GHz white | phy1tpt | Any 5GHz radio activity |
| USB3 white | Off | Unused |

---

## Captive Portal Pages

### 1. Main Splash Page
First page guests see. Shows psyop-cat image and a satirical 10-point notice about participating in an experimental Wi-Fi powered psyop campaign. "I Accept" button grants internet access through the standard OpenNDS auth flow.

### 2. Privacy Notice
Long, tedious, invasive, corporate-formatted satirical privacy policy. Starts with "ourinformation" image, ends with "alwayswatching" image.

### 3. Guaranteed Security
Claims the portal uses cultist encryption technology. Contains ~30 lines of cursed PEM-like certificate text between `---- PRAYERS BEGIN ----` and `---- PRAYERS END ----`.

### 4. Status Page
Clean, serious page showing real OpenNDS session data (IP, MAC, session times, data usage). Available via HTTP (OpenNDS built-in) and HTTPS (uhttpd CGI). Shows "welcome-owl" image.

---

## Rollback

Backups are created in `/tmp/owlred-backup-<timestamp>/` before any changes.

```bash
ssh root@10.10.10.1
ls /tmp/owlred-backup-*

# Restore all configs
for cfg in network wireless firewall dhcp system uhttpd opennds; do
  cp /tmp/owlred-backup-XXXXX/${cfg}.bak /etc/config/${cfg}
done
reboot
```

**Warning:** `/tmp/` is cleared on reboot. Copy backups to persistent storage if needed.

---

## SSH Key Authentication

To avoid password auth:

```bash
ssh-keygen -t ed25519
ssh-copy-id root@10.10.10.1
```

Then leave `ROUTER_PASS` empty in `.env`.

---

## Technical Notes

- **OpenWrt 25.x uses `apk`**, not `opkg`
- **Dropbear lacks sftp-server** — script uses `scp -O` (legacy protocol)
- **ThemeSpec scripts must be busybox ash compatible** — no bashisms
- **OpenNDS MHD binds 0.0.0.0:2050** — iptables redirects port 80 from captive clients
- **CPD browsers block `<a href>` links** — all portal navigation uses `<form>` buttons
- **`max_page_size` set to 65536** — default 10240 is too small for the privacy page
- **Config templates use `%%VAR%%` syntax** — sed-substituted at deploy time with `|` delimiter
- **CRLF handling** — `.gitattributes` enforces LF; deploy script strips `\r` as safety net

---

## Troubleshooting

| Problem | Check |
|---------|-------|
| Portal doesn't appear | `ssh root@<ip> 'pidof opennds'` and `logread \| grep opennds` |
| No CSS / broken styling | `ls /etc/opennds/htdocs/splash.css` on router |
| Images missing | `ls /etc/opennds/htdocs/images/` on router |
| Pages truncated | `uci get opennds.@opennds[0].max_page_size` (should be 65536) |
| WiFi not visible | `iwinfo` on router, check `option disabled '0'` in wireless config |
| Can't reach Luci | Luci is bound to LAN IP only (10.10.10.1) — connect via LAN |
| HTTPS cert failed | `logread \| grep acme`, verify CF_TOKEN permissions |
| IoT can't reach internet | Check `iot → wan` forwarding in `fw4 print` |

---

## Secrets

- `.env` contains credentials and is **gitignored**
- `sshpass -e` passes password via environment variable (not visible in `ps`)
- Cloudflare credentials stored on router at `/etc/acme/cloudflare.env` (mode 600)
- SSH `StrictHostKeyChecking` is disabled for convenience

---

## License

Portal content and scripts are provided as-is for use with the owl.red network. OpenNDS is licensed under the GNU GPL.
