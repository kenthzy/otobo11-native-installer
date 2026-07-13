#!/usr/bin/env bash

#############################################
# OTOBOSuite - OTOBO Management Suite
# MariaDB Installation Module
#############################################

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

prompt_db_engine() {
    source "$SCRIPT_DIR/lib/config.sh"
    load_config

    local cfg_engine
    cfg_engine=$(config_value "DB_ENGINE" "")

    if [[ -n "$cfg_engine" ]]; then
        DB_ENGINE="$cfg_engine"
        info "Using DB engine from config file: $DB_ENGINE"
        return
    fi

    echo
    echo -e "${BOLD}Database Engine Selection${NC}"
    echo -e "${BOLD}-------------------------${NC}"
    echo
    echo " Choose your database engine:"
    echo "   1) MariaDB  (default) — Recommended for OTOBO"
    echo "   2) PostgreSQL         — Experimental support"
    echo
    read -rp " Enter your choice [1/2] (default: 1): " engine_choice

    if [[ "$engine_choice" == "2" ]]; then
        DB_ENGINE="postgresql"
    else
        DB_ENGINE="mariadb"
    fi
}

prompt_db_credentials() {
    local creds_file="/root/.otobo_db_credentials"

    source "$SCRIPT_DIR/lib/config.sh"

    # Silent mode — values from config file
    if load_config; then
        OTOBO_DB_NAME=$(config_value "DB_NAME" "otobo")
        OTOBO_DB_USER=$(config_value "DB_USER" "otobo")
        local cfg_pass
        cfg_pass=$(config_value "DB_PASSWORD" "")
        if [[ -n "$cfg_pass" ]]; then
            OTOBO_DB_PASSWORD="$cfg_pass"
            info "Using DB credentials from $CONFIG_FILE"
            return
        fi
    fi

    # Interactive mode
    echo
    echo -e "${BOLD}Database Configuration${NC}"
    echo -e "${BOLD}----------------------${NC}"
    echo
    info "Press Enter to accept the default value shown in brackets."
    echo

    read -rp " Database name [otobo]: " input_name
    OTOBO_DB_NAME="${input_name:-otobo}"

    read -rp " Database user [otobo]: " input_user
    OTOBO_DB_USER="${input_user:-otobo}"

    echo
    info "Password options:"
    echo "   1) Generate a random password (recommended)"
    echo "   2) Type your own password"
    echo
    read -rp " Choose [1/2] (default: 1): " pw_choice

    if [[ "$pw_choice" == "2" ]]; then
        echo
        read -rsp " Enter password for DB user '${OTOBO_DB_USER}': " OTOBO_DB_PASSWORD
        echo
        read -rsp " Confirm password: " pw_confirm
        echo
        echo
        if [[ "$OTOBO_DB_PASSWORD" != "$pw_confirm" ]]; then
            error "Passwords do not match."
        fi
        if [[ -z "$OTOBO_DB_PASSWORD" ]]; then
            error "Password cannot be empty."
        fi
    else
        OTOBO_DB_PASSWORD=$(openssl rand -base64 32 | head -c32 && echo)
        info "Random password generated."
    fi
}

install_mariadb() {
    local db_root_password
    local creds_file="/root/.otobo_db_credentials"

    source "$SCRIPT_DIR/lib/config.sh"
    load_config

    prompt_db_credentials

    info "Installing MariaDB server..."

    apt-get install -y mariadb-server mariadb-client mysqltuner

    success "MariaDB packages installed."

    info "Starting and enabling MariaDB..."

    systemctl enable mariadb
    systemctl restart mariadb

    success "MariaDB is running."

    info "Securing MariaDB installation..."

    mysql <<-EOF
		DELETE FROM mysql.user WHERE User='';
		DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
		DROP DATABASE IF EXISTS test;
		DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
		FLUSH PRIVILEGES;
	EOF

    success "MariaDB secured (anonymous users removed, remote root disabled)."

    info "Writing OTOBO-optimized MariaDB configuration..."

    cat >/etc/mysql/mariadb.conf.d/99-otobo.cnf <<-'EOF'
		[mysqld]
		max_allowed_packet    = 64M
		query_cache_size      = 64M
		innodb_log_file_size  = 256M
		character-set-server  = utf8mb4
		collation-server      = utf8mb4_unicode_ci

		[mysql]
		default-character-set = utf8mb4

		[client]
		default-character-set = utf8mb4
	EOF

    success "OTBO-optimized MariaDB configuration applied."

    info "Restarting MariaDB to apply configuration..."

    systemctl restart mariadb

    success "MariaDB configuration applied."

    info "Generating root password and writing credentials..."

    db_root_password=$(openssl rand -base64 32 | head -c32 && echo)

    cat >"$creds_file" <<-EOF
		# OTOBO Database Credentials
		# Generated: $(date '+%Y-%m-%d %H:%M:%S')
		# Store this file securely: chmod 600
		# Root uses unix_socket auth — this password is stored for reference.
		DB_ENGINE=mariadb
		DB_ROOT_PASSWORD=${db_root_password}
		OTOBO_DB_HOST=localhost
		OTOBO_DB_PORT=3306
		OTOBO_DB_NAME=${OTOBO_DB_NAME}
		OTOBO_DB_USER=${OTOBO_DB_USER}
		OTOBO_DB_PASSWORD=${OTOBO_DB_PASSWORD}
	EOF

    chmod 600 "$creds_file"

    success "Database credentials stored in ${creds_file}"

    register_result "MariaDBInstall" "PASS" "MariaDB 10.11+, configured for OTOBO"
}
