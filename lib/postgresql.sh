#!/usr/bin/env bash

#############################################
# OTOBOSuite - OTOBO Management Suite
# PostgreSQL Installation Module
#############################################

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

install_postgresql() {
    local db_root_password
    local creds_file="/root/.otobo_db_credentials"

    source "$SCRIPT_DIR/lib/mariadb.sh"
    source "$SCRIPT_DIR/lib/config.sh"
    load_config

    prompt_db_credentials

    info "Installing PostgreSQL server..."

    apt-get install -y postgresql postgresql-client

    success "PostgreSQL packages installed."

    info "Starting and enabling PostgreSQL..."

    systemctl enable postgresql
    systemctl restart postgresql

    sleep 2

    success "PostgreSQL is running."

    info "Configuring PostgreSQL for OTOBO..."

    local pg_version
    pg_version=$(psql --version 2>/dev/null | grep -oP '\d+' | head -1)

    if [[ -z "$pg_version" ]]; then
        pg_version=$(find /etc/postgresql/ -maxdepth 1 -type d -name '[0-9]*' 2>/dev/null | head -1)
        pg_version="${pg_version##*/}"
    fi

    if [[ -n "$pg_version" && -f "/etc/postgresql/${pg_version}/main/postgresql.conf" ]]; then
        cat >>"/etc/postgresql/${pg_version}/main/postgresql.conf" <<-EOF

			# OTOBOSuite OTOBO-optimized settings
			max_connections = 200
			shared_buffers = 256MB
			work_mem = 16MB
			maintenance_work_mem = 64MB
			effective_cache_size = 512MB
		EOF

        systemctl restart postgresql
        success "PostgreSQL configuration applied."
    else
        warning "Could not find PostgreSQL config directory. Skipping optimization."
    fi

    info "Generating root password and writing credentials..."

    db_root_password=$(openssl rand -base64 32 | head -c32 && echo)

    cat >"$creds_file" <<-EOF
		# OTOBO Database Credentials
		# Generated: $(date '+%Y-%m-%d %H:%M:%S')
		# Store this file securely: chmod 600
		DB_ENGINE=postgresql
		DB_ROOT_PASSWORD=${db_root_password}
		OTOBO_DB_HOST=localhost
		OTOBO_DB_PORT=5432
		OTOBO_DB_NAME=${OTOBO_DB_NAME}
		OTOBO_DB_USER=${OTOBO_DB_USER}
		OTOBO_DB_PASSWORD=${OTOBO_DB_PASSWORD}
	EOF

    chmod 600 "$creds_file"

    success "Database credentials stored in ${creds_file}"

    register_result "PostgreSQLInstall" "PASS" "PostgreSQL ${pg_version}+, configured for OTOBO"
}
