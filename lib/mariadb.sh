#!/usr/bin/env bash

install_mariadb() {
	info "Installing MariaDB server..."
	pkg_install mariadb-server mariadb-client
	systemctl enable mariadb
	systemctl start mariadb
	register_result "MariaDB Install" "OK" "MariaDB installed successfully"
}

configure_mariadb_db() {
	local db_name="$1"
	local db_user="$2"
	local db_pass="$3"
	info "Creating MariaDB database $db_name and user $db_user..."
	mysql -u root <<SQL
CREATE DATABASE IF NOT EXISTS \`${db_name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${db_user}'@'localhost' IDENTIFIED BY '${db_pass}';
GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'localhost';
FLUSH PRIVILEGES;
SQL
	register_result "MariaDB DB Setup" "OK" "Database $db_name and user $db_user created"
}

configure_mariadb_dsn() {
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
    \$Self->{DatabaseDSN}    = "DBI:mysql:database=${db_name};host=${db_host};port=${db_port}";
    \$Self->{DatabaseType}   = 'mysql';
}
1;
EOF
	chown otobo:www-data /opt/otobo/Kernel/Config.pm
	chmod 640 /opt/otobo/Kernel/Config.pm
	register_result "MariaDB DSN" "OK" "DSN configured for $db_name on $db_host:$db_port"
}
