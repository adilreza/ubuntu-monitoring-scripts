#!/usr/bin/env bash
# Install Grafana Alloy SSH journal forwarding on Ubuntu.
# Usage: sudo bash install-ubuntu-ssh-alloy.sh <INB_MONITORING_PRIVATE_IP>
# Safe to rerun if previously configured by this script.
set -Eeuo pipefail

log() { printf '[INFO] %s\n' "$*"; }
err() { printf '[ERROR] %s\n' "$*" >&2; }
trap 'err "Installer stopped at line $LINENO"' ERR

[[ "$EUID" -eq 0 ]] || { err 'Run with sudo'; exit 1; }
[[ -f /etc/os-release ]] || { err 'Ubuntu OS info not found'; exit 1; }
# Avoid sourcing /etc/os-release into an installer that defines VERSION.
OS_ID="$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"')"
[[ "$OS_ID" == 'ubuntu' ]] || { err 'Only Ubuntu is supported'; exit 1; }
LOKI_HOST="${1:-}"
[[ -n "$LOKI_HOST" ]] || { err 'Usage: sudo bash install-ubuntu-ssh-alloy.sh <INB_MONITORING_PRIVATE_IP>'; exit 1; }
[[ "$LOKI_HOST" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]] || { err 'Invalid monitoring server hostname/IP'; exit 1; }
SERVER="$(hostname -s)"
[[ "$SERVER" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || { err 'Invalid local short hostname'; exit 1; }

log "Configuring SSH audit forwarding from ${SERVER} to ${LOKI_HOST}:3100"

# Refuse to replace an unrelated Alloy configuration.
if [[ -f /etc/alloy/config.alloy ]] && ! grep -Fq '// managed-by: central-ssh-audit-installer' /etc/alloy/config.alloy; then
  if dpkg-query -W -f='${Status}' alloy 2>/dev/null | grep -Fxq 'install ok installed'; then
    err 'Alloy already has a configuration not managed by this script. No changes made.'
    err 'Manually merge the SSH source into your existing /etc/alloy/config.alloy.'
    exit 1
  fi
fi

log 'Installing prerequisites'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl gnupg

log 'Checking central Loki readiness (must be reachable from this server)'
if ! curl --noproxy '*' -fsS --connect-timeout 3 --max-time 8 "http://${LOKI_HOST}:3100/ready"; then
  err "Cannot reach ready Loki at http://${LOKI_HOST}:3100/ready"
  err 'Start Loki centrally and allow inbound TCP 3100 from this Ubuntu server.'
  exit 1
fi
printf '\n'

log 'Installing Grafana Alloy from official APT repository'
install -d -m 0755 /etc/apt/keyrings
if [[ ! -s /etc/apt/keyrings/grafana.asc ]]; then
  curl -fsSL https://apt.grafana.com/gpg-full.key -o /etc/apt/keyrings/grafana.asc
fi
chmod 0644 /etc/apt/keyrings/grafana.asc
printf '%s\n' 'deb [signed-by=/etc/apt/keyrings/grafana.asc] https://apt.grafana.com stable main' > /etc/apt/sources.list.d/grafana.list
apt-get update
apt-get install -y alloy

# Journal access requires these groups, without running Alloy as root.
getent group adm >/dev/null || { err 'Missing adm group'; exit 1; }
getent group systemd-journal >/dev/null || { err 'Missing systemd-journal group'; exit 1; }
usermod -aG adm,systemd-journal alloy

install -d -m 0750 -o root -g alloy /etc/alloy
TEMP_CONFIG="$(mktemp /etc/alloy/config.alloy.new.XXXXXX)"
trap 'rm -f "$TEMP_CONFIG"' EXIT
cat > "$TEMP_CONFIG" <<ALLOY_CONFIG
// managed-by: central-ssh-audit-installer
// Reads ssh.service journal events and forwards them to central Loki.
logging {
  level = "info"
}

loki.source.journal "ssh_auth" {
  matches    = "_SYSTEMD_UNIT=ssh.service"
  max_age    = "24h"
  labels     = { service = "ssh-audit", host = "${SERVER}" }
  forward_to = [loki.write.central.receiver]
}

loki.write "central" {
  endpoint {
    url = "http://${LOKI_HOST}:3100/loki/api/v1/push"
  }
}
ALLOY_CONFIG

log 'Validating Alloy configuration before installing it'
alloy validate "$TEMP_CONFIG"
if [[ -f /etc/alloy/config.alloy ]]; then
  cp -a /etc/alloy/config.alloy "/etc/alloy/config.alloy.bak.$(date +%Y%m%d%H%M%S)"
fi
install -o root -g alloy -m 0640 "$TEMP_CONFIG" /etc/alloy/config.alloy

log 'Enabling and restarting Alloy'
systemctl enable --now alloy.service
systemctl restart alloy.service
if ! systemctl is-active --quiet alloy.service; then
  journalctl -u alloy.service -n 30 --no-pager >&2 || true
  err 'Alloy service is not active'
  exit 1
fi
log "SUCCESS: Alloy is running on ${SERVER} and forwarding SSH events to ${LOKI_HOST}:3100"
log 'Loki labels: service="ssh-audit", host="'"${SERVER}"'"'
log 'Source verification: sudo journalctl -u ssh.service --since "1 hour ago" --no-pager | grep -E "Accepted|Failed"'
log 'Shipping diagnostics: sudo journalctl -u alloy -n 60 --no-pager'
