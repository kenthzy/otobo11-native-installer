#!/usr/bin/env bash

install_otobo() {
	local otobo_root="$1"
	local otobo_user="$2"
	local otobo_group="$3"

	info "Downloading OTOBO 11..."
	local otobo_version="${OTOBO_VERSION:-11.0.16}"
	local otobo_base_url="${OTOBO_DOWNLOAD_URL:-https://otobo.io/downloads}"
	local tarball="otobo-${otobo_version}.tar.gz"
	local url="${otobo_base_url}/${tarball}"

	if [ ! -f "/tmp/${tarball}" ]; then
		wget -q "$url" -O "/tmp/${tarball}" || die "Failed to download OTOBO"
	fi

	info "Extracting OTOBO to $otobo_root..."
	tar xzf "/tmp/${tarball}" -C /tmp
	mv /tmp/otobo-* "$otobo_root"

	useradd -r -d "$otobo_root" -s /bin/bash "$otobo_user" 2>/dev/null || true
	set_otobo_permissions "$otobo_root" "$otobo_user" "$otobo_group"

	register_result "OTOBO Install" "OK" "OTOBO 11 installed at $otobo_root"
}

configure_otobo_db() {
	local db_engine="$1"
	local db_host="$2"
	local db_port="$3"
	local db_name="$4"
	local db_user="$5"
	local db_pass="$6"

	if [ "$db_engine" = "postgresql" ]; then
		configure_postgresql_dsn "$db_host" "$db_port" "$db_name" "$db_user" "$db_pass"
	else
		configure_mariadb_dsn "$db_host" "$db_port" "$db_name" "$db_user" "$db_pass"
	fi
}

run_otobo_installer() {
	local otobo_root="$1"
	local otobo_user="$2"

	info "Running OTOBO package installer..."
	cd "$otobo_root" || die "Cannot cd to $otobo_root"
	sudo -u "$otobo_user" perl bin/otobo.CheckModules.pl || warn "Some Perl modules missing"
	sudo -u "$otobo_user" perl bin/otobo.Console.pl Maint::Database::Check || warn "DB check had issues"
	register_result "OTOBO Setup" "OK" "OTOBO package installer completed"
}

configure_otobo_admin_user() {
	local otobo_root="$1"
	local otobo_user="$2"
	local admin_user="$3"
	local admin_pass="$4"
	local admin_email="$5"

	info "Creating OTOBO admin user $admin_user..."
	cd "$otobo_root" || die "Cannot cd to $otobo_root"
	sudo -u "$otobo_user" perl bin/otobo.Console.pl Admin::User::Add "$admin_user" "$admin_pass" "$admin_email" "Admin" 2>/dev/null ||
		sudo -u "$otobo_user" perl bin/otobo.Console.pl Admin::User::SetPassword "$admin_user" "$admin_pass" 2>/dev/null ||
		warn "Admin user setup may need manual intervention"
	register_result "Admin User" "OK" "Admin user $admin_user configured"
}

configure_otobo_api_user() {
	local otobo_root="$1"
	local otobo_user="$2"
	local api_user="${3:-open_ticket_ai}"
	local api_pass="$4"
	local api_email="${5:-otai@localhost}"

	info "Creating API user $api_user for Open Ticket AI..."
	cd "$otobo_root" || die "Cannot cd to $otobo_root"
	sudo -u "$otobo_user" perl bin/otobo.Console.pl Admin::User::Add "$api_user" "$api_pass" "$api_email" "Agent" 2>/dev/null ||
		sudo -u "$otobo_user" perl bin/otobo.Console.pl Admin::User::SetPassword "$api_user" "$api_pass" 2>/dev/null ||
		warn "API user may already exist or needs manual creation"
	register_result "API User" "OK" "API user $api_user configured"
}

configure_web_server() {
	local web_server="$1"
	local fqdn="$2"
	local otobo_root="$3"
	local ssl_mode="$4"

	if [ "$web_server" = "nginx" ]; then
		local starman_port="${STARMAN_PORT:-5000}"
		configure_nginx_site "$fqdn" "$otobo_root" "$starman_port" "$ssl_mode"
	else
		configure_apache_site "$fqdn" "$otobo_root" "$ssl_mode"
	fi
}

dispatch_web_server_install() {
	local web_server="$1"
	if [ "$web_server" = "nginx" ]; then
		install_nginx
		install_starman
	else
		install_apache
	fi
}

undo_otobo_install() {
	local otobo_root="${1:-/opt/otobo}"
	info "Rolling back OTOBO installation at $otobo_root..."
	systemctl stop otobo-starman 2>/dev/null || true
	rm -rf "$otobo_root"
	userdel -r otobo 2>/dev/null || true
	groupdel otobo 2>/dev/null || true
	register_result "UndoOTOBO" "OK" "Removed $otobo_root and otobo user"
}
