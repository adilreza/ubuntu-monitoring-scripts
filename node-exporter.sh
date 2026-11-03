#!/usr/bin/env bash
# Node Exporter + active SSH session metrics for Ubuntu AMD64.
# Re-runnable. Set NODE_EXPORTER_BIND_IP to a local IP to avoid a wildcard listener.
set -Eeuo pipefail

NODE_EXPORTER_VERSION="1.12.1"
NODE_EXPORTER_SHA256="b51d8a76aa2a9156a55d501aca6276fae09e262259a5e4e831d2c2222f084e63"
NODE_EXPORTER_BIND_IP="${NODE_EXPORTER_BIND_IP:-0.0.0.0}"
NODE_EXPORTER_PORT="9100"
METRICS_DIR="/var/lib/node_exporter/textfile_collector"

info() { printf '[INFO] %s\n' "$*"; }
fatal() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
trap 'printf "[ERROR] Installer failed on line %s\n" "$LINENO" >&2' ERR

[[ "$EUID" -eq 0 ]] || fatal 'Run as root: sudo bash node-exporter.sh'
[[ -f /etc/os-release ]] || fatal '/etc/os-release not found'
# Check OS, but never source /etc/os-release (it has its own VERSION variable).
grep -qx 'ID=ubuntu' /etc/os-release || fatal 'This script supports Ubuntu only'
[[ "$(uname -m)" == 'x86_64' ]] || fatal 'This installer is for x86_64/amd64 Ubuntu'

if [[ "$NODE_EXPORTER_BIND_IP" != '0.0.0.0' ]]; then
  ip -o -4 addr show | grep -Fq "inet ${NODE_EXPORTER_BIND_IP}/" || fatal "IP ${NODE_EXPORTER_BIND_IP} is not assigned to this machine"
fi

info "Installing Node Exporter v${NODE_EXPORTER_VERSION} on $(hostname)"
info 'Installing prerequisites'
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl tar ca-certificates iproute2 coreutils procps >/dev/null

if systemctl is-active --quiet prometheus-node-exporter.service 2>/dev/null; then
  fatal 'Ubuntu packaged prometheus-node-exporter.service is already active. Disable it first to avoid a port conflict.'
fi

TEMP_DIR="$(mktemp -d)"

trap 'rm -rf "$TEMP_DIR"' EXIT
ARCHIVE="node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"
DOWNLOAD="https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/${ARCHIVE}"
info "Downloading ${DOWNLOAD}"
curl --fail --location --retry 3 --retry-delay 2 --output "$TEMP_DIR/$ARCHIVE" "$DOWNLOAD"
printf '%s  %s\n' "$NODE_EXPORTER_SHA256" "$TEMP_DIR/$ARCHIVE" | sha256sum --check --status || fatal 'Checksum verification failed'
info 'Checksum verified'
tar -xzf "$TEMP_DIR/$ARCHIVE" -C "$TEMP_DIR"

if ! id node_exporter >/dev/null 2>&1; then
  useradd --system --no-create-home --shell /usr/sbin/nologin node_exporter
fi
install -d -o node_exporter -g node_exporter -m 0755 "$METRICS_DIR"
systemctl stop node_exporter.service 2>/dev/null || true
install -m 0755 "$TEMP_DIR/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64/node_exporter" /usr/local/bin/node_exporter

info 'Installing SSH session metrics collector'
cat > /usr/local/bin/ssh-session-metrics.sh <<'SSH_COLLECTOR_SCRIPT_END'
#!/usr/bin/env bash
set -Eeuo pipefail
METRICS_DIR='/var/lib/node_exporter/textfile_collector'
OUTPUT="$METRICS_DIR/ssh.prom"
TEMP="$(mktemp "$METRICS_DIR/ssh.prom.tmp.XXXXXX")"
trap 'rm -f "$TEMP"' EXIT

# who tracks interactive remote terminals; this is not a full SSH audit log.
SESSIONS="$(who | awk '/\([^)]+\)[[:space:]]*$/ { n++ } END { print n+0 }')"
# Counts established inbound SSH TCP connections (assuming SSH port 22).
CONNECTIONS="$(ss -Htn state established '( sport = :22 )' | awk 'END {print NR+0}')"

{
  printf '# HELP ssh_active_sessions Active interactive remote login sessions reported by who.\n'
  printf '# TYPE ssh_active_sessions gauge\n'
  printf 'ssh_active_sessions %s\n' "$SESSIONS"
  printf '# HELP ssh_established_connections Established TCP connections to SSH port 22.\n'
  printf '# TYPE ssh_established_connections gauge\n'
  printf 'ssh_established_connections %s\n' "$CONNECTIONS"
  printf '# HELP ssh_session_metrics_last_updated_seconds Unix timestamp of last successful SSH metrics sample.\n'
  printf '# TYPE ssh_session_metrics_last_updated_seconds gauge\n'
  printf 'ssh_session_metrics_last_updated_seconds %s\n' "$(date +%s)"
} > "$TEMP"
chmod 0644 "$TEMP"
mv -f "$TEMP" "$OUTPUT"
SSH_COLLECTOR_SCRIPT_END
chmod 0755 /usr/local/bin/ssh-session-metrics.sh

cat > /etc/systemd/system/node_exporter.service <<SYSTEMD_NODE_EXPORTER_END
[Unit]
Description=Prometheus Node Exporter
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=node_exporter
Group=node_exporter
ExecStart=/usr/local/bin/node_exporter --web.listen-address=${NODE_EXPORTER_BIND_IP}:${NODE_EXPORTER_PORT} --collector.textfile.directory=${METRICS_DIR}
Restart=on-failure
RestartSec=5s
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
SYSTEMD_NODE_EXPORTER_END

cat > /etc/systemd/system/ssh-session-metrics.service <<'SYSTEMD_SSH_SERVICE_END'
[Unit]
Description=Collect current SSH sessions for Node Exporter

[Service]
Type=oneshot
User=root
ExecStart=/usr/local/bin/ssh-session-metrics.sh
SYSTEMD_SSH_SERVICE_END

cat > /etc/systemd/system/ssh-session-metrics.timer <<'SYSTEMD_SSH_TIMER_END'
[Unit]
Description=Update SSH metrics each minute

[Timer]
OnBootSec=20s
OnUnitInactiveSec=60s
AccuracySec=5s

[Install]
WantedBy=timers.target
SYSTEMD_SSH_TIMER_END

info 'Starting services'
systemctl daemon-reload
systemctl enable --now node_exporter.service
systemctl enable --now ssh-session-metrics.timer
systemctl start ssh-session-metrics.service
systemctl is-active --quiet node_exporter.service || fatal 'Node Exporter service failed'
systemctl is-active --quiet ssh-session-metrics.timer || fatal 'SSH collection timer failed'

CHECK_IP="$NODE_EXPORTER_BIND_IP"
[[ "$CHECK_IP" == '0.0.0.0' ]] && CHECK_IP='127.0.0.1'
curl --noproxy '*' --fail --silent --show-error --max-time 10 "http://${CHECK_IP}:${NODE_EXPORTER_PORT}/metrics" > "$TEMP_DIR/metrics.txt"
grep -q '^node_cpu_seconds_total' "$TEMP_DIR/metrics.txt" || fatal 'CPU metrics missing'
grep -q '^ssh_active_sessions' "$TEMP_DIR/metrics.txt" || fatal 'SSH metrics missing'
info 'SUCCESS: Node Exporter and SSH metrics collector are active'
info "Exporter: http://${CHECK_IP}:${NODE_EXPORTER_PORT}/metrics"
info 'Allow TCP 9100 only from the central Prometheus server in your firewall/ACLs'
