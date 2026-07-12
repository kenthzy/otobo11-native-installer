#!/usr/bin/env bash

#############################################
# OTOBOSuite - OTOBO Management Suite
# MariaDB Installation Module
#############################################

install_mariadb() {
    local db_root_password
    local otobo_db_password
    local creds_file="/root/.otobo_db_credentials"

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

    info "Generating database credentials..."

    db_root_password=$(openssl rand -base64 32 | head -c32 && echo)
    otobo_db_password=$(openssl rand -base64 32 | head -c32 && echo)

    cat >"$creds_file" <<-EOF
		# OTOBO Database Credentials
		# Generated: $(date '+%Y-%m-%d %H:%M:%S')
		# Store this file securely: chmod 600
		# Root uses unix_socket auth — this password is stored for reference.
		DB_ROOT_PASSWORD=${db_root_password}
		OTOBO_DB_HOST=localhost
		OTOBO_DB_PORT=3306
		OTOBO_DB_NAME=otobo
		OTOBO_DB_USER=otobo
		OTOBO_DB_PASSWORD=${otobo_db_password}
	EOF

    chmod 600 "$creds_file"

    success "Database credentials stored in ${creds_file}"

    register_result "MariaDBInstall" "PASS" "MariaDB 10.11+, configured for OTOBO"
}
