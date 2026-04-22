#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# owl.red — OpenWrt Full-Stack Provisioning Script
#
# Provisions a D-Link DIR-885L running OpenWrt 25.x from near-factory-reset
# state. Deploys: network, WiFi (3 VLANs), firewall, DHCP/DNS, system,
# uhttpd, OpenNDS captive portal, and optional HTTPS via Let's Encrypt.
#
# Usage: ./deploy-dir885l.sh
#
# Reads configuration from .env (KEY=VALUE format, no quotes needed).
# Config templates live in config/ with %%VARIABLE%% placeholders.
#
# Requirements: bash 4+, ssh, scp, sshpass (for password auth)
#
# Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>
# ─────────────────────────────────────────────────────────────────────────────

###############################################################################
# Phase 0: Init
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

# --- Color helpers ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

log_info()  { printf "${BLUE}[INFO]${NC}  %s\n" "$*"; }
log_ok()    { printf "${GREEN}[ OK ]${NC}  %s\n" "$*"; }
log_warn()  { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
log_error() { printf "${RED}[FAIL]${NC}  %s\n" "$*" >&2; }
log_step()  { printf "\n${BOLD}==> %s${NC}\n" "$*"; }

# --- Temp-file cleanup ---
TEMP_FILES=()
FIRMWARE_CHANGED=false
cleanup() {
	for f in "${TEMP_FILES[@]}"; do
		rm -f "$f" 2>/dev/null
	done
}
trap cleanup EXIT

# --- Load .env (line-by-line, CRLF-safe) ---
ROUTER_IP=""
ROUTER_USER=""
ROUTER_PASS=""
HOSTNAME_CFG=""
DOMAIN=""
TIMEZONE=""
TZ_OFFSET=""
COUNTRY_CODE=""
LAN_IP=""
GUEST_IP=""
IOT_IP=""
LAN_SSID=""
LAN_WIFI_KEY=""
GUEST_SSID=""
GUEST_WIFI_KEY=""
IOT_SSID=""
IOT_WIFI_KEY=""
CF_TOKEN=""
CF_ACCOUNT_ID=""
CF_ZONE_ID=""

if [ -f "$SCRIPT_DIR/.env" ]; then
	while IFS= read -r line || [ -n "$line" ]; do
		line="${line%$'\r'}"
		case "$line" in \#*|'') continue ;; esac
		key="${line%%=*}"
		value="${line#*=}"
		# Strip surrounding quotes if present
		value="${value#\"}"
		value="${value%\"}"
		value="${value#\'}"
		value="${value%\'}"
		case "$key" in
			ROUTER_IP)       ROUTER_IP="$value" ;;
			ROUTER_USER)     ROUTER_USER="$value" ;;
			ROUTER_PASS)     ROUTER_PASS="$value" ;;
			HOSTNAME)        HOSTNAME_CFG="$value" ;;
			DOMAIN)          DOMAIN="$value" ;;
			TIMEZONE)        TIMEZONE="$value" ;;
			TZ_OFFSET)       TZ_OFFSET="$value" ;;
			COUNTRY_CODE)    COUNTRY_CODE="$value" ;;
			LAN_IP)          LAN_IP="$value" ;;
			GUEST_IP)        GUEST_IP="$value" ;;
			IOT_IP)          IOT_IP="$value" ;;
			LAN_SSID)        LAN_SSID="$value" ;;
			LAN_WIFI_KEY)    LAN_WIFI_KEY="$value" ;;
			GUEST_SSID)      GUEST_SSID="$value" ;;
			GUEST_WIFI_KEY)  GUEST_WIFI_KEY="$value" ;;
			IOT_SSID)        IOT_SSID="$value" ;;
			IOT_WIFI_KEY)    IOT_WIFI_KEY="$value" ;;
			CF_TOKEN)        CF_TOKEN="$value" ;;
			CF_ACCOUNT_ID)   CF_ACCOUNT_ID="$value" ;;
			CF_ZONE_ID)      CF_ZONE_ID="$value" ;;
		esac
	done < "$SCRIPT_DIR/.env"
fi

# --- Prompt for missing critical values ---
if [ -z "$ROUTER_IP" ]; then
	read -rp "Router IP address: " ROUTER_IP
fi
[ -z "$ROUTER_IP" ] && { log_error "ROUTER_IP is required."; exit 1; }

[ -z "$ROUTER_USER" ] && ROUTER_USER="root"

if [ -z "$ROUTER_PASS" ]; then
	read -rsp "Password for $ROUTER_USER@$ROUTER_IP (Enter for SSH key auth): " ROUTER_PASS
	echo
fi

# --- Validate required vars ---
MISSING=()
[ -z "$HOSTNAME_CFG" ]   && MISSING+=("HOSTNAME")
[ -z "$DOMAIN" ]         && MISSING+=("DOMAIN")
[ -z "$TIMEZONE" ]       && MISSING+=("TIMEZONE")
[ -z "$TZ_OFFSET" ]      && MISSING+=("TZ_OFFSET")
[ -z "$COUNTRY_CODE" ]   && MISSING+=("COUNTRY_CODE")
[ -z "$LAN_IP" ]         && MISSING+=("LAN_IP")
[ -z "$GUEST_IP" ]       && MISSING+=("GUEST_IP")
[ -z "$IOT_IP" ]         && MISSING+=("IOT_IP")
[ -z "$LAN_SSID" ]       && MISSING+=("LAN_SSID")
[ -z "$LAN_WIFI_KEY" ]   && MISSING+=("LAN_WIFI_KEY")
[ -z "$GUEST_SSID" ]     && MISSING+=("GUEST_SSID")
[ -z "$GUEST_WIFI_KEY" ] && MISSING+=("GUEST_WIFI_KEY")
[ -z "$IOT_SSID" ]       && MISSING+=("IOT_SSID")
[ -z "$IOT_WIFI_KEY" ]   && MISSING+=("IOT_WIFI_KEY")

if [ ${#MISSING[@]} -gt 0 ]; then
	log_error "Missing required .env variables: ${MISSING[*]}"
	exit 1
fi

# --- Detect sshpass ---
USE_SSHPASS=false
if [ -n "$ROUTER_PASS" ]; then
	if which sshpass >/dev/null 2>&1; then
		USE_SSHPASS=true
	else
		log_error "Password set but sshpass is not installed."
		echo ""
		log_info "Install sshpass:"
		log_info "  Debian/Ubuntu/WSL: sudo apt install sshpass"
		log_info "  macOS:             brew install hudochenkov/sshpass/sshpass"
		log_info "  Arch:              sudo pacman -S sshpass"
		echo ""
		log_info "Or remove ROUTER_PASS from .env and use SSH key auth."
		exit 1
	fi
fi

# --- SSH / SCP helpers ---
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR"

run_ssh() {
	if [ "$USE_SSHPASS" = true ]; then
		SSHPASS="$ROUTER_PASS" sshpass -e ssh $SSH_OPTS "$ROUTER_USER@$ROUTER_IP" "$@"
	else
		ssh $SSH_OPTS "$ROUTER_USER@$ROUTER_IP" "$@"
	fi
}

run_scp() {
	if [ "$USE_SSHPASS" = true ]; then
		SSHPASS="$ROUTER_PASS" sshpass -e scp -O $SSH_OPTS "$@"
	else
		scp -O $SSH_OPTS "$@"
	fi
}

# Escape a string for use in a sed replacement with | delimiter.
# Handles &, \, and | which are special in sed replacements.
escape_sed() {
	printf '%s' "$1" | sed 's/[&\\|]/\\&/g'
}

# --- Validate local files ---
log_step "Phase 0: Validating local files"

REQUIRED_FILES=(
	"config/network"
	"config/wireless"
	"config/firewall"
	"config/dhcp"
	"config/system"
	"config/uhttpd"
	"config/opennds"
	"firmware/brcmfmac4366b-pcie.bin"
	"htdocs/splash.css"
	"htdocs/index.html"
	"htdocs/cgi-bin/status"
	"themespec/theme_owlred.sh"
	"themespec/client_params_owlred.sh"
)

# Firmware integrity check (BCM4366B 5GHz fix)
FIRMWARE_FILE="$SCRIPT_DIR/firmware/brcmfmac4366b-pcie.bin"
FIRMWARE_EXPECTED_MD5="92d1baab27d88b3ff1c9b9a39c33b0b4"
FIRMWARE_EXPECTED_SIZE=1146907

missing=0
for f in "${REQUIRED_FILES[@]}"; do
	if [ ! -f "$SCRIPT_DIR/$f" ]; then
		log_error "Missing: $f"
		missing=1
	fi
done

if [ ! -d "$SCRIPT_DIR/portal" ]; then
	log_error "Missing: portal/ directory"
	missing=1
fi

if [ "$missing" -eq 1 ]; then
	log_error "Required files are missing. Aborting."
	exit 1
fi

log_ok "All local files present."

# Verify firmware integrity
if command -v md5sum >/dev/null 2>&1; then
	ACTUAL_MD5=$(md5sum "$FIRMWARE_FILE" | awk '{print $1}')
elif command -v md5 >/dev/null 2>&1; then
	ACTUAL_MD5=$(md5 -q "$FIRMWARE_FILE")
else
	log_warn "No md5sum/md5 available — skipping firmware hash check."
	ACTUAL_MD5="$FIRMWARE_EXPECTED_MD5"
fi

ACTUAL_SIZE=$(wc -c < "$FIRMWARE_FILE" | tr -d ' ')

if [ "$ACTUAL_MD5" != "$FIRMWARE_EXPECTED_MD5" ]; then
	log_error "Firmware MD5 mismatch!"
	log_error "  Expected: $FIRMWARE_EXPECTED_MD5"
	log_error "  Got:      $ACTUAL_MD5"
	exit 1
fi

if [ "$ACTUAL_SIZE" -ne "$FIRMWARE_EXPECTED_SIZE" ]; then
	log_error "Firmware size mismatch! Expected $FIRMWARE_EXPECTED_SIZE, got $ACTUAL_SIZE"
	exit 1
fi

log_ok "Firmware integrity verified (MD5: ${ACTUAL_MD5:0:12}..., ${ACTUAL_SIZE} bytes)"

# Warn about oversized images
for img in "$SCRIPT_DIR"/portal/*; do
	[ -f "$img" ] || continue
	if stat --version &>/dev/null 2>&1; then
		size=$(stat -c%s "$img" 2>/dev/null || echo 0)
	else
		size=$(stat -f%z "$img" 2>/dev/null || echo 0)
	fi
	if [ "${size:-0}" -gt 512000 ]; then
		log_warn "$(basename "$img") is $((size / 1024))KB — large for router flash"
	fi
done

###############################################################################
# Phase 1: Connect & Discover
###############################################################################
phase1_connect() {
	log_step "Phase 1: Connect & Discover"

	log_info "Testing SSH to $ROUTER_USER@$ROUTER_IP ..."
	if ! run_ssh "echo ok" >/dev/null 2>&1; then
		log_error "Cannot connect to $ROUTER_USER@$ROUTER_IP"
		log_info "Verify: IP address, SSH enabled, credentials."
		exit 1
	fi
	log_ok "SSH connection successful."

	# Read radio hardware paths (needed for wireless template)
	RADIO0_PATH=$(run_ssh "uci get wireless.radio0.path 2>/dev/null" | tr -d '\r\n')
	RADIO1_PATH=$(run_ssh "uci get wireless.radio1.path 2>/dev/null" | tr -d '\r\n')
	if [ -z "$RADIO0_PATH" ] || [ -z "$RADIO1_PATH" ]; then
		log_error "Could not read radio hardware paths from router."
		log_info "Ensure wireless radios exist: uci show wireless"
		exit 1
	fi
	log_ok "radio0: $RADIO0_PATH"
	log_ok "radio1: $RADIO1_PATH"

	# Read OpenWrt version
	OPENWRT_VERSION=$(run_ssh "sed -n \"s/^DISTRIB_RELEASE='\\(.*\\)'/\\1/p\" /etc/openwrt_release 2>/dev/null" | tr -d '\r\n')
	log_info "OpenWrt version: ${OPENWRT_VERSION:-unknown}"

	# Detect whether deploying network config will change the router's IP
	IP_WILL_CHANGE=false
	TARGET_LAN_IP="$LAN_IP"
	if [ "$ROUTER_IP" != "$TARGET_LAN_IP" ]; then
		CURRENT_LAN=$(run_ssh "uci get network.lan.ipaddr 2>/dev/null" | tr -d '\r\n' | sed 's|/.*||')
		if [ "$CURRENT_LAN" != "$TARGET_LAN_IP" ]; then
			IP_WILL_CHANGE=true
			log_warn "Router IP will change from $ROUTER_IP to $TARGET_LAN_IP after config deploy."
		fi
	fi
}

###############################################################################
# Phase 2: Packages
###############################################################################
phase2_packages() {
	log_step "Phase 2: Packages"

	log_info "Updating package index ..."
	run_ssh "apk update" >/dev/null 2>&1
	log_ok "Package index updated."

	# Full system upgrade BEFORE firmware fix — if done after, apk upgrade
	# would pull back the broken stock BCM4366B firmware blob.
	log_info "Upgrading all packages (before firmware fix) ..."
	run_ssh "apk upgrade --no-interactive 2>&1" | tail -5
	log_ok "System packages upgraded."

	# OpenNDS requires dnsmasq-full for nftset support (captive portal redirect).
	# Replace base dnsmasq if present.
	if run_ssh "apk list -I 2>/dev/null | grep -q '^dnsmasq-full-'"; then
		log_ok "dnsmasq-full already installed."
	else
		log_info "Replacing dnsmasq with dnsmasq-full (required for OpenNDS) ..."
		run_ssh "apk add --force-overwrite dnsmasq-full" 2>&1 | tail -3
		log_ok "dnsmasq-full installed."
	fi

	# OpenNDS
	if ! run_ssh "apk list -I 2>/dev/null | grep -q '^opennds-'"; then
		log_info "Installing opennds ..."
		run_ssh "apk add opennds" 2>&1 | tail -3
		log_ok "opennds installed."
	else
		log_ok "opennds already installed."
	fi

	# ACME (only if Cloudflare token provided)
	if [ -n "$CF_TOKEN" ]; then
		if ! run_ssh "apk list -I 2>/dev/null | grep -q '^acme-'"; then
			log_info "Installing ACME packages ..."
			run_ssh "apk add acme acme-acmesh acme-acmesh-dnsapi" 2>&1 | tail -3
			log_ok "ACME packages installed."
		else
			log_ok "ACME packages already installed."
		fi
	fi
}

###############################################################################
# Phase 3: Backup
###############################################################################
phase3_backup() {
	log_step "Phase 3: Backup"

	BACKUP_DIR="/tmp/owlred-backup-$TIMESTAMP"
	log_info "Backup directory: $BACKUP_DIR"

	run_ssh "mkdir -p '$BACKUP_DIR'"

	# Backup UCI configs
	local configs=(network wireless firewall dhcp system uhttpd opennds)
	for cfg in "${configs[@]}"; do
		run_ssh "cp -f '/etc/config/$cfg' '$BACKUP_DIR/${cfg}.bak' 2>/dev/null || true"
	done

	# Backup portal files
	run_ssh "
		cp -f  /etc/opennds/htdocs/splash.css                '$BACKUP_DIR/splash.css.bak'                  2>/dev/null || true
		cp -rf /etc/opennds/htdocs/images                     '$BACKUP_DIR/images.bak'                      2>/dev/null || true
		cp -f  /usr/lib/opennds/theme_owlred.sh               '$BACKUP_DIR/theme_owlred.sh.bak'             2>/dev/null || true
		cp -f  /usr/lib/opennds/client_params_owlred.sh       '$BACKUP_DIR/client_params_owlred.sh.bak'     2>/dev/null || true
		cp -f  /www-guest/index.html                          '$BACKUP_DIR/index.html.bak'                  2>/dev/null || true
		cp -f  /www-guest/cgi-bin/status                      '$BACKUP_DIR/status.bak'                      2>/dev/null || true
	"

	# Backup radio firmware (BCM4366B)
	run_ssh "cp -f /lib/firmware/brcm/brcmfmac4366b-pcie.bin '$BACKUP_DIR/brcmfmac4366b-pcie.bin.bak' 2>/dev/null || true"

	log_ok "Backup created at $BACKUP_DIR"
}

###############################################################################
# Phase 3b: WiFi Firmware Fix (BCM4366B — DIR-885L 5GHz fix)
###############################################################################
phase3b_firmware() {
	log_step "Phase 3b: WiFi Firmware (BCM4366B 5GHz fix)"

	# Check if firmware already matches
	REMOTE_MD5=$(run_ssh "md5sum /lib/firmware/brcm/brcmfmac4366b-pcie.bin 2>/dev/null | awk '{print \$1}'" | tr -d '\r\n')
	if [ "$REMOTE_MD5" = "$FIRMWARE_EXPECTED_MD5" ]; then
		log_ok "Firmware already patched — skipping."
		FIRMWARE_CHANGED=false
		return
	fi

	log_warn "Stock BCM4366B firmware detected — replacing with known-good v10.10.122.45"
	log_info "This fixes 5GHz association/stability issues on DIR-885L."

	run_scp "$FIRMWARE_FILE" "$ROUTER_USER@$ROUTER_IP:/lib/firmware/brcm/brcmfmac4366b-pcie.bin"

	# Verify upload
	UPLOADED_MD5=$(run_ssh "md5sum /lib/firmware/brcm/brcmfmac4366b-pcie.bin | awk '{print \$1}'" | tr -d '\r\n')
	if [ "$UPLOADED_MD5" != "$FIRMWARE_EXPECTED_MD5" ]; then
		log_error "Firmware upload verification failed!"
		log_error "  Expected: $FIRMWARE_EXPECTED_MD5"
		log_error "  Got:      $UPLOADED_MD5"
		exit 1
	fi

	FIRMWARE_CHANGED=true
	log_ok "Firmware deployed and verified."
}

###############################################################################
# Phase 4: Template & Deploy Configs
###############################################################################
phase4_configs() {
	log_step "Phase 4: Template & Deploy Configs"

	# Pre-escape all substitution values for sed (| delimiter)
	local e_RADIO0_PATH e_RADIO1_PATH e_COUNTRY_CODE
	local e_LAN_SSID e_LAN_WIFI_KEY e_GUEST_SSID e_GUEST_WIFI_KEY
	local e_IOT_SSID e_IOT_WIFI_KEY e_HOSTNAME e_TZ_OFFSET e_TIMEZONE e_DOMAIN
	local e_LAN_IP e_GUEST_IP e_IOT_IP

	e_RADIO0_PATH=$(escape_sed "$RADIO0_PATH")
	e_RADIO1_PATH=$(escape_sed "$RADIO1_PATH")
	e_COUNTRY_CODE=$(escape_sed "$COUNTRY_CODE")
	e_LAN_IP=$(escape_sed "$LAN_IP")
	e_GUEST_IP=$(escape_sed "$GUEST_IP")
	e_IOT_IP=$(escape_sed "$IOT_IP")
	e_LAN_SSID=$(escape_sed "$LAN_SSID")
	e_LAN_WIFI_KEY=$(escape_sed "$LAN_WIFI_KEY")
	e_GUEST_SSID=$(escape_sed "$GUEST_SSID")
	e_GUEST_WIFI_KEY=$(escape_sed "$GUEST_WIFI_KEY")
	e_IOT_SSID=$(escape_sed "$IOT_SSID")
	e_IOT_WIFI_KEY=$(escape_sed "$IOT_WIFI_KEY")
	e_HOSTNAME=$(escape_sed "$HOSTNAME_CFG")
	e_TZ_OFFSET=$(escape_sed "$TZ_OFFSET")
	e_TIMEZONE=$(escape_sed "$TIMEZONE")
	e_DOMAIN=$(escape_sed "$DOMAIN")

	local configs=(network wireless firewall dhcp system uhttpd opennds)
	for cfg in "${configs[@]}"; do
		local src="$SCRIPT_DIR/config/$cfg"
		local tmp
		tmp=$(mktemp)
		TEMP_FILES+=("$tmp")

		cp "$src" "$tmp"
		sed -i 's/\r$//' "$tmp"

		case "$cfg" in
			network)
				sed -i \
					-e "s|%%LAN_IP%%|${e_LAN_IP}|g" \
					-e "s|%%GUEST_IP%%|${e_GUEST_IP}|g" \
					-e "s|%%IOT_IP%%|${e_IOT_IP}|g" \
					"$tmp"
				;;
			wireless)
				sed -i \
					-e "s|%%RADIO0_PATH%%|${e_RADIO0_PATH}|g" \
					-e "s|%%RADIO1_PATH%%|${e_RADIO1_PATH}|g" \
					-e "s|%%COUNTRY_CODE%%|${e_COUNTRY_CODE}|g" \
					-e "s|%%LAN_SSID%%|${e_LAN_SSID}|g" \
					-e "s|%%LAN_WIFI_KEY%%|${e_LAN_WIFI_KEY}|g" \
					-e "s|%%GUEST_SSID%%|${e_GUEST_SSID}|g" \
					-e "s|%%GUEST_WIFI_KEY%%|${e_GUEST_WIFI_KEY}|g" \
					-e "s|%%IOT_SSID%%|${e_IOT_SSID}|g" \
					-e "s|%%IOT_WIFI_KEY%%|${e_IOT_WIFI_KEY}|g" \
					"$tmp"
				;;
			dhcp)
				sed -i \
					-e "s|%%DOMAIN%%|${e_DOMAIN}|g" \
					-e "s|%%LAN_IP%%|${e_LAN_IP}|g" \
					-e "s|%%GUEST_IP%%|${e_GUEST_IP}|g" \
					"$tmp"
				;;
			system)
				sed -i \
					-e "s|%%HOSTNAME%%|${e_HOSTNAME}|g" \
					-e "s|%%TZ_OFFSET%%|${e_TZ_OFFSET}|g" \
					-e "s|%%TIMEZONE%%|${e_TIMEZONE}|g" \
					"$tmp"
				;;
			uhttpd)
				sed -i \
					-e "s|%%LAN_IP%%|${e_LAN_IP}|g" \
					-e "s|%%GUEST_IP%%|${e_GUEST_IP}|g" \
					"$tmp"
				# Strip the guest uhttpd section if HTTPS won't be configured
				if [ -z "$CF_TOKEN" ]; then
					sed -i "/^config uhttpd 'guest'/,\$d" "$tmp"
				fi
				;;
		esac

		run_scp "$tmp" "$ROUTER_USER@$ROUTER_IP:/etc/config/$cfg"
		log_ok "$cfg deployed."
	done

	# Safety net: strip any stray CRLF that survived
	run_ssh "sed -i 's/\r\$//' /etc/config/*"
	log_ok "All configs deployed and sanitized."
}

###############################################################################
# Phase 5: Deploy Portal Files
###############################################################################
phase5_portal() {
	log_step "Phase 5: Deploy Portal Files"

	# Create target directories
	run_ssh "mkdir -p /etc/opennds/htdocs/images /www-guest/cgi-bin /www-guest/images /usr/lib/opennds"

	# CSS
	log_info "Deploying splash.css ..."
	run_scp "$SCRIPT_DIR/htdocs/splash.css" "$ROUTER_USER@$ROUTER_IP:/etc/opennds/htdocs/splash.css"
	run_ssh "sed -i 's/\r\$//' /etc/opennds/htdocs/splash.css"
	log_ok "splash.css deployed."

	# Images
	log_info "Deploying portal images ..."
	for img in "$SCRIPT_DIR"/portal/*; do
		[ -f "$img" ] || continue
		local filename
		filename=$(basename "$img")
		run_scp "$img" "$ROUTER_USER@$ROUTER_IP:/etc/opennds/htdocs/images/$filename"
		log_ok "  $filename"
	done

	# ThemeSpec scripts
	log_info "Deploying ThemeSpec scripts ..."
	run_scp "$SCRIPT_DIR/themespec/theme_owlred.sh" \
		"$ROUTER_USER@$ROUTER_IP:/usr/lib/opennds/theme_owlred.sh"
	run_scp "$SCRIPT_DIR/themespec/client_params_owlred.sh" \
		"$ROUTER_USER@$ROUTER_IP:/usr/lib/opennds/client_params_owlred.sh"
	run_ssh "
		chmod +x /usr/lib/opennds/theme_owlred.sh /usr/lib/opennds/client_params_owlred.sh
		sed -i 's/\r\$//' /usr/lib/opennds/theme_owlred.sh /usr/lib/opennds/client_params_owlred.sh
	"
	log_ok "ThemeSpec scripts deployed."

	# Guest web files
	log_info "Deploying guest web files ..."
	run_scp "$SCRIPT_DIR/htdocs/index.html" "$ROUTER_USER@$ROUTER_IP:/www-guest/index.html"
	run_scp "$SCRIPT_DIR/htdocs/cgi-bin/status" "$ROUTER_USER@$ROUTER_IP:/www-guest/cgi-bin/status"
	run_ssh "
		chmod +x /www-guest/cgi-bin/status
		sed -i 's/\r\$//' /www-guest/index.html /www-guest/cgi-bin/status
	"
	log_ok "Guest web files deployed."

	# Symlinks
	log_info "Creating symlinks ..."
	run_ssh "
		ln -sf /etc/opennds/htdocs/splash.css            /www-guest/splash.css
		ln -sf /etc/opennds/htdocs/images/welcome-owl.jpg /www-guest/images/welcome-owl.jpg
		ln -sf /etc/opennds/htdocs/images/psyop-cat.png   /www-guest/images/psyop-cat.png
	"
	log_ok "Symlinks created."
}

###############################################################################
# Phase 6: Apply Configuration
###############################################################################
phase6_apply() {
	log_step "Phase 6: Apply Configuration"

	if [ "$IP_WILL_CHANGE" = true ]; then
		log_warn "Network config will change router IP to $TARGET_LAN_IP."
		log_warn "SSH session will disconnect. Router will reboot."

		# Single fire-and-forget command: apply everything, then reboot
		run_ssh "
			service network restart
			service firewall restart
			sleep 2
			reboot
		" >/dev/null 2>&1 || true

		log_info "Waiting for router at $TARGET_LAN_IP (up to 90s) ..."
		ROUTER_IP="$TARGET_LAN_IP"

		local elapsed=0
		while [ "$elapsed" -lt 90 ]; do
			sleep 5
			elapsed=$((elapsed + 5))
			if run_ssh "echo ok" >/dev/null 2>&1; then
				log_ok "Router is back at $ROUTER_IP (${elapsed}s)"
				return
			fi
			printf "."
		done
		echo
		log_error "Router did not come back within 90s at $TARGET_LAN_IP."
		log_info "Check physical connectivity and try: ssh $ROUTER_USER@$TARGET_LAN_IP"
		exit 1

	else
		log_info "Restarting network ..."
		run_ssh "service network restart" 2>/dev/null || true
		sleep 5

		log_info "Restarting firewall ..."
		run_ssh "service firewall restart" 2>/dev/null || true
		sleep 3

		log_info "Restarting dnsmasq ..."
		run_ssh "service dnsmasq restart" 2>/dev/null || true

		log_info "Restarting uhttpd ..."
		run_ssh "service uhttpd restart" 2>/dev/null || true

		log_info "Restarting OpenNDS ..."
		run_ssh "/etc/init.d/opennds stop 2>/dev/null; sleep 2; killall -9 opennds 2>/dev/null; sleep 3; /etc/init.d/opennds start" 2>/dev/null || true

		log_info "Waiting 10s for OpenNDS to initialize ..."
		sleep 10
		log_ok "Services restarted."
	fi
}

###############################################################################
# Phase 7: HTTPS (optional — requires CF_TOKEN)
###############################################################################
phase7_https() {
	if [ -z "$CF_TOKEN" ]; then
		log_info "Skipping HTTPS setup (no CF_TOKEN in .env)."
		return
	fi

	log_step "Phase 7: HTTPS via Let's Encrypt (Cloudflare DNS-01)"

	# Verify ACME packages are present
	if ! run_ssh "apk list -I 2>/dev/null | grep -q '^acme-'"; then
		log_error "ACME packages not installed — skipping HTTPS."
		return
	fi

	# Write Cloudflare credentials
	log_info "Writing Cloudflare credentials ..."
	local cf_cred="CF_Token=${CF_TOKEN}"
	[ -n "$CF_ACCOUNT_ID" ] && cf_cred="${cf_cred}
CF_Account_ID=${CF_ACCOUNT_ID}"
	[ -n "$CF_ZONE_ID" ] && cf_cred="${cf_cred}
CF_Zone_ID=${CF_ZONE_ID}"

	run_ssh "mkdir -p /etc/acme && cat > /etc/acme/cloudflare.env << 'CFEOF'
${cf_cred}
CFEOF
chmod 600 /etc/acme/cloudflare.env"

	# --- Guest cert: guest.DOMAIN ---
	local guest_fqdn="guest.${DOMAIN}"
	local guest_cert_dir="/etc/acme/${guest_fqdn}_ecc"

	log_info "Checking certificate for ${guest_fqdn} ..."
	if run_ssh "test -f '${guest_cert_dir}/fullchain.cer'" 2>/dev/null; then
		log_ok "Certificate for ${guest_fqdn} already exists."
	else
		log_info "Issuing certificate for ${guest_fqdn} (may take 30-120s) ..."
		local acme_out
		acme_out=$(run_ssh "
			. /etc/acme/cloudflare.env
			export CF_Token CF_Account_ID CF_Zone_ID
			/usr/lib/acme/client/acme.sh --issue --dns dns_cf \
				-d '${guest_fqdn}' --keylength ec-256 \
				--home /etc/acme --server letsencrypt 2>&1
		" 2>&1) || true
		echo "$acme_out" | tail -5

		if run_ssh "test -f '${guest_cert_dir}/fullchain.cer'" 2>/dev/null; then
			log_ok "Certificate issued for ${guest_fqdn}."
		else
			log_warn "Certificate not issued for ${guest_fqdn}. Check: logread | grep acme"
		fi
	fi

	# --- Management cert: hostname.DOMAIN (e.g. wap1.owl.red) ---
	local mgmt_fqdn="${HOSTNAME_CFG,,}.${DOMAIN}"
	local mgmt_cert_dir="/etc/acme/${mgmt_fqdn}_ecc"

	log_info "Checking certificate for ${mgmt_fqdn} ..."
	if run_ssh "test -f '${mgmt_cert_dir}/fullchain.cer'" 2>/dev/null; then
		log_ok "Certificate for ${mgmt_fqdn} already exists."
	else
		log_info "Issuing certificate for ${mgmt_fqdn} (may take 30-120s) ..."
		local acme_out2
		acme_out2=$(run_ssh "
			. /etc/acme/cloudflare.env
			export CF_Token CF_Account_ID CF_Zone_ID
			/usr/lib/acme/client/acme.sh --issue --dns dns_cf \
				-d '${mgmt_fqdn}' --keylength ec-256 \
				--home /etc/acme --server letsencrypt 2>&1
		" 2>&1) || true
		echo "$acme_out2" | tail -5

		if run_ssh "test -f '${mgmt_cert_dir}/fullchain.cer'" 2>/dev/null; then
			log_ok "Certificate issued for ${mgmt_fqdn}."
		else
			log_warn "Certificate not issued for ${mgmt_fqdn}. Check: logread | grep acme"
		fi
	fi

	# --- Configure uhttpd with real certs ---
	log_info "Configuring uhttpd with certificates ..."

	# Guest uhttpd instance
	if run_ssh "test -f '${guest_cert_dir}/fullchain.cer'" 2>/dev/null; then
		run_ssh "
			uci set uhttpd.guest=uhttpd
			uci set uhttpd.guest.listen_https='${GUEST_IP}:443'
			uci set uhttpd.guest.home='/www-guest'
			uci set uhttpd.guest.cgi_prefix='/cgi-bin'
			uci set uhttpd.guest.max_requests='3'
			uci set uhttpd.guest.max_connections='50'
			uci set uhttpd.guest.script_timeout='30'
			uci set uhttpd.guest.network_timeout='15'
			uci set uhttpd.guest.redirect_https='0'
			uci set uhttpd.guest.rfc1918_filter='0'
			uci set uhttpd.guest.cert='${guest_cert_dir}/fullchain.cer'
			uci set uhttpd.guest.key='${guest_cert_dir}/${guest_fqdn}.key'
			uci commit uhttpd
		" 2>/dev/null
		log_ok "Guest uhttpd HTTPS configured (${guest_fqdn})."
	fi

	# Main (LuCI) uhttpd certs
	if run_ssh "test -f '${mgmt_cert_dir}/fullchain.cer'" 2>/dev/null; then
		run_ssh "
			uci set uhttpd.main.cert='${mgmt_cert_dir}/fullchain.cer'
			uci set uhttpd.main.key='${mgmt_cert_dir}/${mgmt_fqdn}.key'
			uci commit uhttpd
		" 2>/dev/null
		log_ok "Main uhttpd HTTPS configured (${mgmt_fqdn})."
	fi

	run_ssh "service uhttpd restart" 2>/dev/null
	log_ok "uhttpd restarted with TLS."

	# --- ACME cron renewal ---
	log_info "Setting up weekly ACME renewal cron ..."
	run_ssh "
		crontab -l 2>/dev/null | grep -v 'acme.sh --cron' > /tmp/cron_owlred || true
		echo '0 3 * * 1 /usr/lib/acme/client/acme.sh --cron --home /etc/acme > /dev/null 2>&1' >> /tmp/cron_owlred
		crontab /tmp/cron_owlred
		rm -f /tmp/cron_owlred
	"
	log_ok "ACME renewal cron installed (weekly Monday 03:00)."
}

###############################################################################
# Phase 8: Verify
###############################################################################
phase8_verify() {
	log_step "Phase 8: Verify"

	local all_ok=true

	# Check critical daemons
	if run_ssh "pidof opennds" >/dev/null 2>&1; then
		log_ok "OpenNDS is running."
	else
		log_error "OpenNDS is NOT running!"
		run_ssh "logread | grep -i opennds | tail -10" 2>/dev/null || true
		all_ok=false
	fi

	if run_ssh "pidof uhttpd" >/dev/null 2>&1; then
		log_ok "uhttpd is running."
	else
		log_warn "uhttpd is NOT running."
		all_ok=false
	fi

	if run_ssh "pidof dnsmasq" >/dev/null 2>&1; then
		log_ok "dnsmasq is running."
	else
		log_warn "dnsmasq is NOT running."
		all_ok=false
	fi

	# WiFi interfaces
	log_info "WiFi interfaces:"
	run_ssh "iwinfo 2>/dev/null | head -20" || true

	# Firewall
	run_ssh "fw4 print-features 2>/dev/null || echo 'fw4 check skipped'" | head -5

	# --- Summary ---
	echo ""
	log_step "Deployment Summary"
	echo ""
	printf "  ${BOLD}LAN${NC}     %s    SSID: %s\n" "$LAN_IP" "$LAN_SSID"
	printf "          LuCI: https://%s/\n" "$LAN_IP"
	echo ""
	printf "  ${BOLD}Guest${NC}   %s    SSID: %s\n" "$GUEST_IP" "$GUEST_SSID"
	printf "          Portal: http://%s/\n" "$GUEST_IP"
	echo ""
	printf "  ${BOLD}IoT${NC}     %s    SSID: %s\n" "$IOT_IP" "$IOT_SSID"
	printf "          (LAN/Guest can reach IoT, IoT has internet)\n"
	echo ""

	if [ -n "$CF_TOKEN" ]; then
		local guest_fqdn="guest.${DOMAIN}"
		local mgmt_fqdn="${HOSTNAME_CFG,,}.${DOMAIN}"

		if run_ssh "test -f '/etc/acme/${guest_fqdn}_ecc/fullchain.cer'" 2>/dev/null; then
			printf "  ${GREEN}HTTPS${NC}   https://${guest_fqdn}/ ✓\n"
		else
			printf "  ${YELLOW}HTTPS${NC}   ${guest_fqdn} — cert pending\n"
		fi
		if run_ssh "test -f '/etc/acme/${mgmt_fqdn}_ecc/fullchain.cer'" 2>/dev/null; then
			printf "  ${GREEN}HTTPS${NC}   https://${mgmt_fqdn}/ ✓\n"
		else
			printf "  ${YELLOW}HTTPS${NC}   ${mgmt_fqdn} — cert pending\n"
		fi
		echo ""
	fi

	log_info "Backup location: $BACKUP_DIR"
	echo ""
	log_info "To rollback:"
	log_info "  ssh $ROUTER_USER@$ROUTER_IP"
	for cfg in network wireless firewall dhcp system uhttpd opennds; do
		log_info "  cp ${BACKUP_DIR}/${cfg}.bak /etc/config/${cfg}"
	done
	log_info "  cp ${BACKUP_DIR}/brcmfmac4366b-pcie.bin.bak /lib/firmware/brcm/brcmfmac4366b-pcie.bin"
	log_info "  reboot"
	echo ""

	if [ "$FIRMWARE_CHANGED" = true ]; then
		log_warn "WiFi firmware was replaced — a reboot is required for it to take effect."
		log_warn "Run: ssh $ROUTER_USER@$ROUTER_IP 'reboot'"
	fi

	if [ "$all_ok" = true ]; then
		log_ok "Provisioning complete. All services healthy."
	else
		log_warn "Provisioning finished with warnings — review service status above."
	fi
}

###############################################################################
# Main
###############################################################################
phase1_connect
phase2_packages
phase3_backup
phase3b_firmware
phase4_configs
phase5_portal
phase6_apply
phase7_https
phase8_verify
