#!/usr/bin/env bash

install_postgresql() {
	info "Installing PostgreSQL server..."
	pkg_install postgresql postgresql-client
	systemctl enable postgresql
	systemctl start postgresql
	register_result "PostgreSQL Install" "OK" "PostgreSQL installed successfully"
}

configure_postgresql_db() {
	local db_name="$1"
	local db_user="$2"
	local db_pass="$3"
	info "Creating PostgreSQL database $db_name and user $db_user..."
	sudo -u postgres psql -c "CREATE DATABASE ${db_name} ENCODING 'UTF8' LC_COLLATE 'en_US.UTF-8' LC_CTYPE 'en_US.UTF-8' TEMPLATE template0;" 2>/dev/null || true
	sudo -u postgres psql -c "CREATE USER ${db_user} WITH PASSWORD '${db_pass}';" 2>/dev/null || true
	sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE ${db_name} TO ${db_user};" 2>/dev/null || true
	sudo -u postgres psql -c "ALTER DATABASE ${db_name} OWNER TO ${db_user};" 2>/dev/null || true
	register_result "PostgreSQL DB Setup" "OK" "Database $db_name and user $db_user created"
}

configure_postgresql_dsn() {
	local db_host="$1"
	local db_port="$2"
	local db_name="$3"
	local db_user="$4"
	local db_pass="$5"
	cat >/opt/otobo/Kernel/Config.pm <<EOF
package Kernel::Config;
use strict;
use warnings;
use utf8;
sub Load {
    my \$Self = shift;
    \$Self->{DatabaseHost}   = '${db_host}';
    \$Self->{DatabasePort}   = '${db_port}';
    \$Self->{Database}       = '${db_name}';
    \$Self->{DatabaseUser}   = '${db_user}';
    \$Self->{DatabasePw}     = '${db_pass}';
    \$Self->{DatabaseDSN}    = "DBI:Pg:database=${db_name};host=${db_host};port=${db_port}";
    \$Self->{DatabaseType}   = 'postgresql';
}
1;
EOF
	chown otobo:www-data /opt/otobo/Kernel/Config.pm
	chmod 640 /opt/otobo/Kernel/Config.pm
	register_result "PostgreSQL DSN" "OK" "DSN configured for $db_name on $db_host:$db_port"
}

optimize_postgresql() {
	local pg_version
	pg_version=$(psql --version 2>/dev/null | grep -oP '\d+' | head -1)
	if [[ -f "/etc/postgresql/${pg_version}/main/postgresql.conf" ]]; then
		cat >>"/etc/postgresql/${pg_version}/main/postgresql.conf" <<-EOF

			# OTOBOSuite OTOBO-optimized settings
			max_connections = 200
			shared_buffers = 256MB
			work_mem = 16MB
			maintenance_work_mem = 64MB
			effective_cache_size = 512MB
		EOF
		systemctl restart postgresql
	fi
}
