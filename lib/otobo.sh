#!/usr/bin/env bash

#############################################
# OTOBOSuite - OTOBO Management Suite
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
    mkdir -p /opt/otobo/Kernel/Config/Files
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
    systemctl enable otobo-web >/dev/null 2>&1 || true

    register_result "OTOBO_Systemd" "PASS" "systemd services installed and enabled"
    success "systemd services configured (enabled, not started)."
}

set_permissions() {
    info "Setting OTOBO file permissions..."

    chown -R otobo:www-data /opt/otobo
    find /opt/otobo -type d -exec chmod 775 {} \;
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

    if [[ "${DB_ENGINE:-mariadb}" == "postgresql" ]]; then
        setup_database_pg
    else
        setup_database_mysql
    fi

    register_result "OTOBO_Database" "PASS" "Database '${OTOBO_DB_NAME}' and user created"
    success "OTOBO database and user created."
}

setup_database_mysql() {
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
}

setup_database_pg() {
    local pg_exists

    pg_exists=$(su - postgres -c "psql -t -c \"SELECT 1 FROM pg_roles WHERE rolname='${OTOBO_DB_USER}'\"" 2>/dev/null | tr -d ' ')
    if [[ "$pg_exists" != "1" ]]; then
        su - postgres -c "psql -c \"CREATE USER ${OTOBO_DB_USER} WITH PASSWORD '${OTOBO_DB_PASSWORD}'\"" 2>/dev/null
    fi

    su - postgres -c "psql -c \"CREATE DATABASE ${OTOBO_DB_NAME} OWNER ${OTOBO_DB_USER} ENCODING 'UTF8' LC_COLLATE 'en_US.UTF-8' LC_CTYPE 'en_US.UTF-8'\"" 2>/dev/null || true

    su - postgres -c "psql -c \"GRANT ALL PRIVILEGES ON DATABASE ${OTOBO_DB_NAME} TO ${OTOBO_DB_USER}\"" 2>/dev/null
}

write_config() {
    local creds_file="/root/.otobo_db_credentials"
    local config_file="/opt/otobo/Kernel/Config/Files/AAInstaller.pm"
    local dist_file="/opt/otobo/Kernel/Config.pm.dist"
    local pm_file="/opt/otobo/Kernel/Config.pm"

    info "Writing OTOBO configuration files..."

    if [[ -f "$dist_file" && ! -f "$pm_file" ]]; then
        cp "$dist_file" "$pm_file"
        chmod 664 "$pm_file"
        chown otobo:www-data "$pm_file"
        info "Created Kernel/Config.pm from Config.pm.dist template."
    fi

    if [[ ! -f "$creds_file" ]]; then
        register_result "OTOBO_Config" "FAIL" "Credentials file not found"
        error "Database credentials file not found: $creds_file"
    fi

    # shellcheck disable=SC1090
    source "$creds_file"

    local dsn
    if [[ "${DB_ENGINE:-mariadb}" == "postgresql" ]]; then
        dsn="DBI:Pg:database=${OTOBO_DB_NAME};host=${OTOBO_DB_HOST};"
    else
        dsn="DBI:mysql:database=${OTOBO_DB_NAME};host=${OTOBO_DB_HOST};"
    fi

    cat >"$config_file" <<-EOF
		package Kernel::Config::Files::AAInstaller;
		use strict;
		use warnings;
		use utf8;

		sub Load {
		    my \$Self = shift;

		    \$Self->{DatabaseHost} = '${OTOBO_DB_HOST}';
		    \$Self->{Database}     = '${OTOBO_DB_NAME}';
		    \$Self->{DatabaseUser} = '${OTOBO_DB_USER}';
		    \$Self->{DatabasePw}   = '${OTOBO_DB_PASSWORD}';
		    \$Self->{DatabaseDSN}  = '${dsn}';

		    return 1;
		}

		1;
	EOF

    chmod 644 "$config_file"
    chown otobo:www-data "$config_file"

    register_result "OTOBO_Config" "PASS" "OTOBO database configuration written"
    success "OTOBO database configuration written."
}

restart_services() {
    info "Restarting Apache..."

    if ! apache2ctl configtest 2>/dev/null; then
        register_result "OTOBO_Services" "FAIL" "Apache config syntax invalid"
        error "Apache configuration syntax error — refusing to restart"
    fi

    systemctl restart apache2

    sleep 3

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

setup_otobo_cli_env() {
    local otobo_home="/opt/otobo"
    export OTOBO_HOME="$otobo_home"
    export PERL5LIB="$otobo_home/Kernel:$otobo_home/Kernel/cpan-lib"
    export PATH="$otobo_home/bin:$PATH"
}

create_admin_user() {
    local admin_email=""
    local admin_password=""
    local otobo_home="/opt/otobo"
    local console="$otobo_home/bin/otobo.Console.pl"

    setup_otobo_cli_env

    if [[ ! -x "$console" ]]; then
        register_result "AdminUser" "SKIP" "otobo.Console.pl not found"
        return
    fi

    source "$SCRIPT_DIR/lib/config.sh"
    load_config

    admin_email=$(config_value "ADMIN_EMAIL" "")
    admin_password=$(config_value "ADMIN_PASSWORD" "")

    # If not set in config, prompt interactively
    if [[ -z "$admin_email" || -z "$admin_password" ]]; then
        echo
        echo -e "${BOLD}OTOBO Admin User${NC}"
        echo -e "${BOLD}----------------${NC}"
        echo
        info "Create an admin user now (or skip and use the web installer later)."
        echo

        if ! confirm "Create admin user now?" "Y"; then
            register_result "AdminUser" "SKIP" "Skipped by user"
            return
        fi
        echo

        read -rp " Admin email (e.g. root@localhost): " admin_email
        while [[ -z "$admin_email" ]]; do
            read -rp " Admin email (e.g. root@localhost): " admin_email
        done

        read -rsp " Admin password: " admin_password
        echo
        while [[ -z "$admin_password" ]]; do
            read -rsp " Admin password: " admin_password
            echo
        done
        echo
    fi

    info "Running database migration..."

    if su -c "$console Maint::Database::Migration --force" otobo 2>/dev/null; then
        register_result "DBMigration" "PASS" "Database schema created"
        success "Database migration completed."
    else
        register_result "DBMigration" "WARN" "Database migration failed — use web installer"
        warning "Database migration could not be completed via CLI."
        warning "Open /otobo/installer.pl in your browser to complete setup."
        return
    fi

    info "Creating admin user..."

    if su -c "$console Admin::User::Add --email \"$admin_email\" --password \"$admin_password\" --firstname Root --lastname User" otobo 2>/dev/null; then
        register_result "AdminUser" "PASS" "Admin user created: $admin_email"
        success "Admin user created: $admin_email"
    else
        register_result "AdminUser" "WARN" "Admin user creation failed — use web installer"
        warning "Could not create admin user via CLI."
        warning "Open /otobo/installer.pl in your browser to create one."
    fi

    info "Starting OTOBO daemon..."

    systemctl start otobo-daemon 2>/dev/null || true
    systemctl start otobo-web 2>/dev/null || true
    register_result "Services" "INFO" "OTOBO services started"
}

show_completion() {
    local server_ip

    server_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    if [[ -z "$server_ip" ]]; then
        server_ip=$(ip route get 8.8.8.8 2>/dev/null | awk '{print $7}')
    fi
    if [[ -z "$server_ip" ]]; then
        server_ip="<your-server-ip>"
    fi

    echo
    echo -e "${BOLD}============================================================${NC}"
    echo -e "${BOLD}$(printf '%*s' 33 "")INSTALLATION COMPLETED${NC}"
    echo -e "${BOLD}============================================================${NC}"
    echo
    echo -e " ${BOLD}URL:${NC}"
    echo -e "    ${LIGHT_BLUE}http://${server_ip}/otobo${NC}"
    echo
    echo -e " ${BOLD}Database credentials:${NC}"
    echo -e "    ${YELLOW}/root/.otobo_db_credentials${NC}"
    echo -e "    ${YELLOW}sudo cat /root/.otobo_db_credentials${NC}"
    echo

    local admin_created=0
    for i in "${!VALIDATION_NAMES[@]}"; do
        if [[ "${VALIDATION_NAMES[$i]}" == "AdminUser" && "${VALIDATION_STATUSES[$i]}" == "PASS" ]]; then
            admin_created=1
            break
        fi
    done

    if [[ "$admin_created" -eq 1 ]]; then
        echo -e " ${BOLD}Admin user:${NC} ${GREEN}Created${NC}"
        echo -e "    Login at ${LIGHT_BLUE}http://${server_ip}/otobo/index.pl${NC}"
        echo
        echo -e " ${BOLD}Services:${NC}"
        echo -e "    ${GREEN}otobo-daemon${NC} and ${GREEN}otobo-web${NC} are running."
        echo
    else
        echo -e " ${BOLD}Next Steps:${NC}"
        echo -e "    1. Open ${LIGHT_BLUE}http://${server_ip}/otobo/installer.pl${NC}"
        echo -e "    2. Complete the OTOBO web installer."
        echo -e "    3. Return to this terminal when finished."
        echo
        echo -e " ${BOLD}After web installer:${NC}"
        echo -e "    sudo systemctl start otobo-daemon"
        echo -e "    sudo systemctl start otobo-web"
        echo
    fi

    echo -e "${BOLD}============================================================${NC}"
    echo

    pause

    echo
    echo -e "${GREEN}✔${NC} ${BOLD}Thank you for using OTOBOSuite.${NC}"
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
    create_admin_user

    show_completion
}
