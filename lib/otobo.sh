#!/usr/bin/env bash

#############################################
# OTOBO 11 Native Installer
# OTOBO Application Module
#############################################

OTOBO_URL="https://ftp.otobo.org/pub/otobo/otobo-latest-11.0.tar.gz"

download_otobo() {
    if [[ -d /opt/otobo/Kernel ]]; then
        register_result "OTOBO_Download" "SKIP" "Already present at /opt/otobo"
        warning "Existing OTOBO installation detected at /opt/otobo."
        warning "Skipping download and extraction."
        return
    fi

    info "Downloading OTOBO 11..."

    if ! command -v wget >/dev/null 2>&1; then
        apt-get install -y wget
    fi

    cd /tmp || error "Cannot change to /tmp"
    wget -q "$OTOBO_URL" -O otobo-latest-11.0.tar.gz

    success "Download complete."

    info "Extracting OTOBO..."

    tar -xzf otobo-latest-11.0.tar.gz

    local otobo_dir
    otobo_dir=$(find /tmp -maxdepth 1 -type d -name 'otobo-11.0*' | head -1)

    if [[ -z "$otobo_dir" ]]; then
        register_result "OTOBO_Download" "FAIL" "Extraction failed — directory not found"
        error "Could not find extracted OTOBO directory."
    fi

    mkdir -p /opt/otobo
    mv "$otobo_dir"/* /opt/otobo/
    rm -f /tmp/otobo-latest-11.0.tar.gz
    cd /

    success "OTOBO extracted to /opt/otobo."

    register_result "OTOBO_Download" "PASS" "OTOBO 11 downloaded and extracted"
}

create_otobo_user() {
    info "Creating OTOBO system user..."

    if id otobo >/dev/null 2>&1; then
        register_result "OTOBO_User" "INFO" "User 'otobo' already exists"
        info "User 'otobo' already exists. Skipping."
        return
    fi

    useradd -r -d /opt/otobo -s /bin/bash -c "OTOBO Daemon User" otobo

    register_result "OTOBO_User" "PASS" "System user 'otobo' created"
    success "OTOBO system user created."
}

configure_apache() {
    info "Configuring Apache for OTOBO..."

    if [[ ! -f /opt/otobo/scripts/apache2-httpd.include.conf ]]; then
        register_result "OTOBO_Apache" "FAIL" "Apache include template not found"
        error "OTOBO Apache template missing: /opt/otobo/scripts/apache2-httpd.include.conf"
    fi

    cp /opt/otobo/scripts/apache2-httpd.include.conf /etc/apache2/sites-available/zzz_otobo.conf

    a2dissite 000-default >/dev/null 2>&1 || true
    a2ensite zzz_otobo >/dev/null 2>&1

    echo "ServerName localhost" >/etc/apache2/conf-available/servername.conf
    a2enconf servername >/dev/null 2>&1 || true

    if ! apache2ctl configtest 2>/dev/null; then
        register_result "OTOBO_Apache" "FAIL" "Apache config syntax invalid"
        error "Apache configuration syntax error in zzz_otobo.conf"
    fi

    register_result "OTOBO_Apache" "PASS" "Apache virtual host configured"
    success "Apache configuration for OTOBO completed."
}

configure_systemd() {
    info "Configuring systemd services..."

    if [[ ! -d /opt/otobo/scripts/systemd ]]; then
        register_result "OTOBO_Systemd" "WARN" "systemd directory not found — skipping"
        warning "OTOBO systemd scripts not found. Skipping."
        return
    fi

    cp /opt/otobo/scripts/systemd/* /etc/systemd/system/
    systemctl daemon-reload

    systemctl enable otobo-daemon >/dev/null 2>&1 || true
    systemctl enable otobo-scheduler >/dev/null 2>&1 || true

    register_result "OTOBO_Systemd" "PASS" "systemd services installed and enabled"
    success "systemd services configured (enabled, not started)."
}

set_permissions() {
    info "Setting OTOBO file permissions..."

    chown -R otobo:www-data /opt/otobo
    find /opt/otobo -type d -exec chmod 755 {} \;
    find /opt/otobo -type f -not -executable -exec chmod 644 {} \;
    chmod 755 /opt/otobo/bin/* 2>/dev/null || true
    chmod 755 /opt/otobo/var/httpd/htdocs/*.pl 2>/dev/null || true

    register_result "OTOBO_Permissions" "PASS" "File permissions set (otobo:www-data)"
    success "OTOBO file permissions configured."
}

setup_database() {
    local creds_file="/root/.otobo_db_credentials"
    info "Setting up OTOBO database..."

    if [[ ! -f "$creds_file" ]]; then
        register_result "OTOBO_Database" "FAIL" "Credentials file not found"
        error "Database credentials file not found: $creds_file"
    fi

    # shellcheck disable=SC1090,SC2153
    source "$creds_file"

    mysql <<-EOF
		CREATE DATABASE IF NOT EXISTS ${OTOBO_DB_NAME}
		    CHARACTER SET utf8mb4
		    COLLATE utf8mb4_unicode_ci;

		CREATE USER IF NOT EXISTS '${OTOBO_DB_USER}'@'${OTOBO_DB_HOST}'
		    IDENTIFIED BY '${OTOBO_DB_PASSWORD}';

		GRANT ALL PRIVILEGES ON ${OTOBO_DB_NAME}.*
		    TO '${OTOBO_DB_USER}'@'${OTOBO_DB_HOST}';

		FLUSH PRIVILEGES;
	EOF

    register_result "OTOBO_Database" "PASS" "Database 'otobo' and user created"
    success "OTOBO database and user created."
}

write_config() {
    local creds_file="/root/.otobo_db_credentials"
    local config_file="/opt/otobo/Kernel/Config.pm"

    info "Writing Kernel/Config.pm..."

    if [[ ! -f "$creds_file" ]]; then
        register_result "OTOBO_Config" "FAIL" "Credentials file not found"
        error "Database credentials file not found: $creds_file"
    fi

    # shellcheck disable=SC1090
    source "$creds_file"

    cat >"$config_file" <<-EOF
		package Kernel::Config;
		use strict;
		use warnings;
		use utf8;

		sub new {
		    my \$type = shift;
		    my \$Self = {};
		    bless(\$Self, \$type);
		    \$Self->Load();
		    return \$Self;
		}

		sub Load {
		    my \$Self = shift;

		    \$Self->{DatabaseHost} = '${OTOBO_DB_HOST}';
		    \$Self->{Database}     = '${OTOBO_DB_NAME}';
		    \$Self->{DatabaseUser} = '${OTOBO_DB_USER}';
		    \$Self->{DatabasePw}   = '${OTOBO_DB_PASSWORD}';
		    \$Self->{DatabaseDSN} = 'DBI:mysql:database=${OTOBO_DB_NAME};host=${OTOBO_DB_HOST};';

		    return 1;
		}

		1;
	EOF

    chmod 644 "$config_file"

    register_result "OTOBO_Config" "PASS" "Kernel/Config.pm written"
    success "OTOBO configuration file written."
}

restart_services() {
    info "Restarting Apache..."

    if ! apache2ctl configtest 2>/dev/null; then
        register_result "OTOBO_Services" "FAIL" "Apache config syntax invalid"
        error "Apache configuration syntax error — refusing to restart"
    fi

    systemctl restart apache2

    if ! systemctl is-active --quiet apache2; then
        register_result "OTOBO_Services" "FAIL" "Apache failed to start"
        error "Apache failed to start after restart"
    fi

    if curl -s -o /dev/null -w "%{http_code}" http://localhost/otobo/installer.pl |
        grep -qE '200|302'; then
        register_result "OTOBO_Services" "PASS" "Apache restarted and serving OTOBO"
        success "Apache restarted and serving OTOBO."
    else
        register_result "OTOBO_Services" "WARN" "Apache restarted but /otobo/ not reachable"
        warning "Apache restarted but /otobo/installer.pl is not responding."
        warning "Run 'sudo ./verify.sh' or 'sudo ./repair.sh --check' to diagnose."
    fi
}

show_completion() {
    local server_ip

    server_ip=$(ip route get 8.8.8.8 2>/dev/null | awk '{print $7}')
    if [[ -z "$server_ip" ]]; then
        server_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    if [[ -z "$server_ip" ]]; then
        server_ip="<your-server-ip>"
    fi

    echo
    echo -e "${BOLD}┌──────────────────────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${BOLD}│                    OTOBO 11 INSTALLATION COMPLETED                          │${NC}"
    echo -e "${BOLD}├──────────────────────────────────────────────────────────────────────────────┤${NC}"
    echo -e "${BOLD}│                                                                              │${NC}"
    echo -e "│  ${BOLD}URL:${NC}                                                                        │"
    echo -e "│  ${LIGHT_BLUE}http://${server_ip}/otobo/installer.pl${NC}                               │"
    echo -e "${BOLD}│                                                                              │${NC}"
    echo -e "│  ${BOLD}Database credentials:${NC}                                                      │"
    echo -e "│  ${YELLOW}/root/.otobo_db_credentials${NC}                                             │"
    echo -e "${BOLD}│                                                                              │${NC}"
    echo -e "│  ${BOLD}Next Steps:${NC}                                                                │"
    echo -e "│  1. Open the URL above in your browser.                                            │"
    echo -e "│  2. Complete the OTOBO web installer.                                              │"
    echo -e "│  3. Return to this terminal when finished.                                         │"
    echo -e "│                                                                                     │"
    echo -e "│  ${BOLD}After web installer:${NC}                                                        │"
    echo -e "│  sudo systemctl start otobo-daemon                                                  │"
    echo -e "│  sudo systemctl start otobo-scheduler                                               │"
    echo -e "${BOLD}│                                                                              │${NC}"
    echo -e "${BOLD}└──────────────────────────────────────────────────────────────────────────────┘${NC}"
    echo

    pause

    echo
    echo -e "${GREEN}✔${NC} ${BOLD}Thank you for using the OTOBO 11 Native Installer.${NC}"
    echo -e "${GREEN}✔${NC} Automated by System Admin Kenneth."
    echo
    success "Installer finished successfully."
    echo
    exit 0
}

install_otobo() {
    line
    info "Phase 4: OTOBO Installation"
    line

    download_otobo
    create_otobo_user
    configure_apache
    configure_systemd
    set_permissions
    setup_database
    write_config
    restart_services

    show_completion
}
