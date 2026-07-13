#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/pkg.sh
source "$SCRIPT_DIR/lib/pkg.sh"
# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"
# shellcheck source=lib/mariadb.sh
source "$SCRIPT_DIR/lib/mariadb.sh"
# shellcheck source=lib/postgresql.sh
source "$SCRIPT_DIR/lib/postgresql.sh"
# shellcheck source=lib/apache.sh
source "$SCRIPT_DIR/lib/apache.sh"
# shellcheck source=lib/nginx.sh
source "$SCRIPT_DIR/lib/nginx.sh"
# shellcheck source=lib/starman.sh
source "$SCRIPT_DIR/lib/starman.sh"
# shellcheck source=lib/perl.sh
source "$SCRIPT_DIR/lib/perl.sh"
# shellcheck source=lib/otobo.sh
source "$SCRIPT_DIR/lib/otobo.sh"
# shellcheck source=lib/ssl.sh
source "$SCRIPT_DIR/lib/ssl.sh"
# shellcheck source=lib/backup.sh
source "$SCRIPT_DIR/lib/backup.sh"
# shellcheck source=lib/firewall.sh
source "$SCRIPT_DIR/lib/firewall.sh"
# shellcheck source=lib/security.sh
source "$SCRIPT_DIR/lib/security.sh"

UNATTENDED=0

parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--unattended | -u)
			UNATTENDED=1
			shift
			;;
		--config | -c)
			if [[ -n "${2:-}" ]]; then
				CONFIG_FILE="$2"
				shift 2
			else
				die "Missing config file path after --config"
			fi
			;;
		*)
			die "Unknown option: $1"
			;;
		esac
	done
}

parse_args "$@"

if [[ "$UNATTENDED" -eq 1 ]]; then
	if ! load_config "$CONFIG_FILE"; then
		die "Config file not found: $CONFIG_FILE"
	fi
	info "Running in unattended mode using $CONFIG_FILE"
	if ! config_is_complete "FQDN" "DB_ENGINE" "DB_NAME" "DB_USER" "DB_PASS" "ADMIN_USER" "ADMIN_PASS"; then
		die "Config file is incomplete. Required keys: FQDN, DB_ENGINE, DB_NAME, DB_USER, DB_PASS, ADMIN_USER, ADMIN_PASS"
	fi
else
	load_config "$CONFIG_FILE" || true
fi

# ===========================================
# Prompt Functions
# ===========================================

prompt_db_engine() {
	[[ "$UNATTENDED" -eq 1 ]] && return
	echo ""
	echo "========================================"
	echo "  Database Engine Selection"
	echo "========================================"
	echo "  1) MariaDB (default)"
	echo "  2) PostgreSQL"
	echo "========================================"
	local choice
	read -r -p "Select database engine [1]: " choice
	case "${choice:-1}" in
	1)
		DB_ENGINE="mariadb"
		DB_PORT="${DB_PORT:-3306}"
		;;
	2)
		DB_ENGINE="postgresql"
		DB_PORT="${DB_PORT:-5432}"
		;;
	*)
		DB_ENGINE="mariadb"
		DB_PORT="${DB_PORT:-3306}"
		;;
	esac
	echo ""
}

prompt_web_server() {
	[[ "$UNATTENDED" -eq 1 ]] && return
	echo ""
	echo "========================================"
	echo "  Web Server Selection"
	echo "========================================"
	echo "  1) Apache with mod_perl (default)"
	echo "  2) nginx with Starman"
	echo "========================================"
	local choice
	read -r -p "Select web server [1]: " choice
	case "${choice:-1}" in
	1) WEB_SERVER="apache" ;;
	2) WEB_SERVER="nginx" ;;
	*) WEB_SERVER="apache" ;;
	esac
	echo ""
}

prompt_db_credentials() {
	[[ "$UNATTENDED" -eq 1 ]] && return
	echo ""
	echo "========================================"
	echo "  Database Credentials"
	echo "========================================"
	DB_NAME=$(prompt_with_default "Database name" "${DB_NAME:-otobo}")
	DB_USER=$(prompt_with_default "Database user" "${DB_USER:-otobo}")
	while [ -z "${DB_PASS:-}" ]; do
		read -r -s -p "Database password: " DB_PASS
		echo ""
		if [ -z "$DB_PASS" ]; then
			echo "Password cannot be empty."
		fi
	done
	echo ""
}

prompt_admin_user() {
	[[ "$UNATTENDED" -eq 1 ]] && return
	echo ""
	echo "========================================"
	echo "  OTOBO Admin User"
	echo "========================================"
	ADMIN_USER=$(prompt_with_default "Admin username" "root@localhost")
	while [ -z "${ADMIN_PASS:-}" ]; do
		read -r -s -p "Admin password: " ADMIN_PASS
		echo ""
		if [ -z "$ADMIN_PASS" ]; then
			echo "Password cannot be empty."
		fi
	done
	ADMIN_EMAIL=$(prompt_with_default "Admin email" "admin@localhost")
	echo ""
}

prompt_ssl() {
	[[ "$UNATTENDED" -eq 1 ]] && return
	echo ""
	echo "========================================"
	echo "  SSL Configuration"
	echo "========================================"
	echo "  1) No SSL (HTTP only)"
	echo "  2) Self-signed certificate"
	echo "  3) Let's Encrypt"
	echo "========================================"
	local choice
	read -r -p "Select SSL option [1]: " choice
	case "${choice:-1}" in
	1) SSL_MODE="none" ;;
	2) SSL_MODE="self-signed" ;;
	3)
		SSL_MODE="letsencrypt"
		SSL_EMAIL=$(prompt_with_default "Email for Let's Encrypt" "admin@${FQDN}")
		;;
	*) SSL_MODE="none" ;;
	esac
	echo ""
}

prompt_ai() {
	[[ "$UNATTENDED" -eq 1 ]] && return
	echo ""
	echo "========================================"
	echo "  Open Ticket AI Integration"
	echo "========================================"
	if prompt_yes_no "Install Open Ticket AI module?"; then
		INSTALL_AI="yes"
		echo ""
		echo "  Select AI model:"
		echo "    1) MiniLM (all-MiniLM-L6-v2) - ~80MB, CPU, default"
		echo "    2) BERT (bert-base-uncased) - ~440MB, more accurate"
		echo "    3) Skip model download (download later)"
		echo "========================================"
		local model_choice
		read -r -p "Select model [1]: " model_choice
		case "${model_choice:-1}" in
		1) AI_MODEL="minilm" ;;
		2) AI_MODEL="bert" ;;
		3) AI_MODEL="skip" ;;
		*) AI_MODEL="minilm" ;;
		esac
		AI_QUEUE=$(prompt_with_default "Queue to monitor" "${AI_QUEUE:-Raw}")
		AI_POLL_INTERVAL=$(prompt_with_default "Poll interval (seconds)" "${AI_POLL_INTERVAL:-60}")
	else
		INSTALL_AI="no"
	fi
	echo ""
}

prompt_hardening() {
	[[ "$UNATTENDED" -eq 1 ]] && return
	echo ""
	echo "========================================"
	echo "  Security Hardening"
	echo "========================================"
	if prompt_yes_no "Apply security hardening? (firewall, fail2ban, auto-updates)"; then
		INSTALL_HARDENING="yes"
	fi
	echo ""
}

prompt_monitoring() {
	[[ "$UNATTENDED" -eq 1 ]] && return
	echo ""
	echo "========================================"
	echo "  Monitoring Stack"
	echo "========================================"
	if prompt_yes_no "Install monitoring? (Prometheus node_exporter, health checks)"; then
		INSTALL_MONITORING="yes"
	fi
	echo ""
}

# ===========================================
# Main Install Flow
# ===========================================

echo ""
echo "========================================"
echo "  OTOBO 11 Native Installer"
echo "========================================"

FQDN=$(prompt_with_default "Fully Qualified Domain Name" "$(hostname -f)")

prompt_db_engine
prompt_web_server
prompt_db_credentials
prompt_admin_user
prompt_ssl
prompt_ai
prompt_hardening
prompt_monitoring

echo ""
echo "========================================"
echo "  Installation Summary"
echo "========================================"
echo "  FQDN:           $FQDN"
echo "  DB Engine:      $DB_ENGINE"
echo "  Web Server:     $WEB_SERVER"
echo "  Database:       $DB_NAME"
echo "  DB User:        $DB_USER"
echo "  SSL:            $SSL_MODE"
echo "  Install AI:     $INSTALL_AI"
echo "  Hardening:      $INSTALL_HARDENING"
echo "  Monitoring:     $INSTALL_MONITORING"
echo "========================================"

if [[ "$UNATTENDED" -eq 0 ]]; then
	if ! prompt_yes_no "Proceed with installation?" "y"; then
		echo "Installation cancelled."
		exit 0
	fi
fi

save_config

info "Starting OTOBO installation..."

# 1. Install database
if [ "$DB_ENGINE" = "postgresql" ]; then
	install_postgresql
	configure_postgresql_db "$DB_NAME" "$DB_USER" "$DB_PASS"
	optimize_postgresql
else
	install_mariadb
	configure_mariadb_db "$DB_NAME" "$DB_USER" "$DB_PASS"
fi

# 2. Install Perl dependencies
install_perl_deps "$DB_ENGINE"

# 3. Install OTOBO
install_otobo "${OTOBO_ROOT:-/opt/otobo}" "${OTOBO_USER:-otobo}" "${OTOBO_GROUP:-www-data}"
configure_otobo_db "$DB_ENGINE" "${DB_HOST:-127.0.0.1}" "$DB_PORT" "$DB_NAME" "$DB_USER" "$DB_PASS"
run_otobo_installer "${OTOBO_ROOT:-/opt/otobo}" "${OTOBO_USER:-otobo}"

# 4. Configure admin user
configure_otobo_admin_user "${OTOBO_ROOT:-/opt/otobo}" "${OTOBO_USER:-otobo}" "$ADMIN_USER" "$ADMIN_PASS" "$ADMIN_EMAIL"

# 5. Install web server
dispatch_web_server_install "$WEB_SERVER"

# 6. SSL
if [ "$SSL_MODE" != "none" ]; then
	configure_ssl "$SSL_MODE"
fi

# 7. Configure web server
configure_web_server "$WEB_SERVER" "$FQDN" "${OTOBO_ROOT:-/opt/otobo}" "$SSL_MODE"

# 8. AI module
if [ "$INSTALL_AI" = "yes" ]; then
	# shellcheck source=lib/ai.sh
	source "$SCRIPT_DIR/lib/ai.sh"
	API_PASS=$(openssl rand -base64 24)
	install_ai_module "${OTOBO_ROOT:-/opt/otobo}" "${OTOBO_USER:-otobo}" "$FQDN" "$API_PASS" "$AI_MODEL" "$AI_QUEUE" "$AI_POLL_INTERVAL"
fi

# 9. Security hardening
if [ "${INSTALL_HARDENING:-no}" = "yes" ]; then
	run_security_hardening
fi

# 10. Monitoring
if [ "${INSTALL_MONITORING:-no}" = "yes" ]; then
	# shellcheck source=lib/monitoring.sh
	source "$SCRIPT_DIR/lib/monitoring.sh"
	install_monitoring_stack
fi

# 11. Backup setup
setup_backup_dir

validation_summary || die "Installation completed with errors"

echo ""
echo "========================================"
echo "  OTOBO 11 Installation Complete!"
echo "========================================"
echo "  URL:      http://${FQDN}/otobo"
echo "  Admin:    $ADMIN_USER"
echo "========================================"
