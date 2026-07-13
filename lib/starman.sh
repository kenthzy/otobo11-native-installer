#!/usr/bin/env bash

install_starman() {
	info "Installing Starman PSGI server..."
	pkg_install starman

	if ! command -v starman >/dev/null 2>&1; then
		cpanm -n Starman 2>/dev/null || true
	fi

	if ! command -v starman >/dev/null 2>&1; then
		register_result "Starman" "FAIL" "Starman could not be installed"
		error "Starman installation failed."
	fi

	success "Starman installed."

	info "Creating Starman systemd service..."
	mkdir -p /run/otobo /opt/otobo/var/log

	cat >/etc/systemd/system/otobo-starman.service <<-UNIT
		[Unit]
		Description=OTOBO Starman PSGI Server
		Documentation=https://otobo.de
		After=network.target mysql.service mariadb.service postgresql.service
		Requires=mysql.service mariadb.service postgresql.service

		[Service]
		Type=simple
		User=otobo
		Group=www-data
		WorkingDirectory=/opt/otobo
		RuntimeDirectory=otobo
		ExecStart=/usr/bin/starman --listen :5000 --workers 4 --pid /run/otobo/starman.pid /opt/otobo/script/psgi-bin/otobo.psgi
		ExecReload=/bin/kill -HUP \\\$MAINPID
		Restart=always
		RestartSec=10
		StandardOutput=append:/opt/otobo/var/log/starman.log
		StandardError=append:/opt/otobo/var/log/starman.log

		[Install]
		WantedBy=multi-user.target
	UNIT

	systemctl daemon-reload
	systemctl enable otobo-starman

	register_result "Starman" "PASS" "Starman PSGI server installed and enabled"
	success "Starman systemd service created."
}

start_starman() {
	info "Starting Starman..."

	if ! systemctl is-active --quiet otobo-starman 2>/dev/null; then
		systemctl start otobo-starman || true
		sleep 2
	fi

	if systemctl is-active --quiet otobo-starman 2>/dev/null; then
		register_result "StarmanStart" "PASS" "Starman is running on port 5000"
		success "Starman started."
	else
		register_result "StarmanStart" "WARN" "Starman may not be running"
		warning "Starman may not have started. Check journalctl -u otobo-starman"
	fi
}
