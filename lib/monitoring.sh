#!/usr/bin/env bash

NODE_EXPORTER_VERSION="1.8.2"
NODE_EXPORTER_URL="https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"

install_node_exporter() {
	info "Installing Prometheus node_exporter v${NODE_EXPORTER_VERSION}..."

	if command -v node_exporter &>/dev/null; then
		info "node_exporter already installed"
		register_result "NodeExporter" "OK" "Already installed"
		return
	fi

	local tmp_dir
	tmp_dir=$(mktemp -d)
	wget -q "$NODE_EXPORTER_URL" -O "${tmp_dir}/node_exporter.tar.gz" || die "Failed to download node_exporter"
	tar xzf "${tmp_dir}/node_exporter.tar.gz" -C "$tmp_dir"
	cp "${tmp_dir}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64/node_exporter" /usr/local/bin/
	chmod 755 /usr/local/bin/node_exporter

	cat >/etc/systemd/system/node_exporter.service <<UNIT
[Unit]
Description=Prometheus Node Exporter
After=network.target

[Service]
Type=simple
User=nobody
ExecStart=/usr/local/bin/node_exporter --web.listen-address=:9100
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

	systemctl daemon-reload
	systemctl enable node_exporter
	systemctl start node_exporter

	rm -rf "$tmp_dir"
	register_result "NodeExporter" "OK" "node_exporter v${NODE_EXPORTER_VERSION} installed on port 9100"
}

configure_otobo_healthcheck() {
	info "Configuring OTOBO health check script..."

	mkdir -p /opt/otobo/scripts

	cat >/opt/otobo/scripts/health_check.sh <<'SCRIPT'
#!/usr/bin/env bash
HEALTH_URL="${1:-http://localhost/otobo/index.pl}"
EXPECTED="${2:-200}"
OUTPUT=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "$HEALTH_URL" 2>/dev/null)
if [ "$OUTPUT" = "$EXPECTED" ] || [ "$OUTPUT" = "302" ] || [ "$OUTPUT" = "303" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] HEALTH OK - $OUTPUT" >> /var/log/otobo_health.log
    exit 0
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] HEALTH FAIL - $OUTPUT" >> /var/log/otobo_health.log
    exit 1
fi
SCRIPT
	chmod 755 /opt/otobo/scripts/health_check.sh
	chown otobo:www-data /opt/otobo/scripts/health_check.sh

	echo "*/5 * * * * otobo /opt/otobo/scripts/health_check.sh >/dev/null 2>&1" >/etc/cron.d/otobo-health

	register_result "HealthCheck" "OK" "Health check script configured (cron every 5min)"
}

install_monitoring_stack() {
	info "Installing monitoring stack..."

	install_node_exporter
	configure_otobo_healthcheck

	register_result "Monitoring" "OK" "Monitoring stack installed"
}
