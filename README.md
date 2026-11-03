# Ubuntu Monitoring Installers

Scripts for an Ubuntu fleet monitored by centralized Prometheus + Grafana + Loki.

- `node-exporter.sh`: installs Node Exporter v1.12.1 and SSH session-count metrics via systemd.
- `install-ubuntu-ssh-alloy.sh`: installs Grafana Alloy and forwards `ssh.service` journal events to central Loki.

Run only on trusted machines and review code before granting root privileges. Both scripts require `sudo`; the Alloy script additionally requires the central Loki private IP or resolvable hostname.

## Public GitHub repository deployment

Replace `OWNER` and the monitoring IP with your actual values.

```bash
set -o pipefail
curl -fsSL https://raw.githubusercontent.com/adilreza/ubuntu-monitoring-scripts/main/node-exporter.sh | sudo bash -s
curl -fsSL https://raw.githubusercontent.com/adilreza/ubuntu-monitoring-scripts/main/install-ubuntu-ssh-alloy.sh | sudo bash -s -- MONITORING_SERVER_PRIVATE_IP
```

For a server-specific Node Exporter bind address:

```bash
curl -fsSL https://raw.githubusercontent.com/OWNER/ubuntu-monitoring-scripts/main/node-exporter.sh | sudo env NODE_EXPORTER_BIND_IP=172.16.2.53 bash -s
```

## Verify

```bash
sudo systemctl is-active node_exporter ssh-session-metrics.timer alloy
curl -fsS http://127.0.0.1:9100/metrics | grep -m1 '^node_cpu_seconds_total'
sudo journalctl -u alloy -n 30 --no-pager
```

Node Exporter is configured to listen on port 9100 by default; use a host firewall or network ACL to restrict access to your Prometheus server. Alloy sends events to TCP 3100, which should be restricted to the monitoring network. `raw.githubusercontent.com` works without credentials only for publicly accessible repositories. For production, pin URLs to an immutable commit SHA, or download and inspect the file before running it as root.
