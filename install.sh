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
# shellcheck source=lib/validation.sh
source "$SCRIPT_DIR/lib/validation.sh"
# shellcheck source=lib/permissions.sh
source "$SCRIPT_DIR/lib/permissions.sh"
# shellcheck source=lib/deb.sh
source "$SCRIPT_DIR/lib/deb.sh"
# shellcheck source=lib/apt_repo.sh
source "$SCRIPT_DIR/lib/apt_repo.sh"

# Prevent per-module register_result overrides (ssl.sh, backup.sh) from
# capturing install-step results in wrong namespaces
register_result() {
	_registry_register "VALIDATION" "$@"
}

UNATTENDED=0
APT_REPO_URL=""
APT_REPO_GPG_KEY_URL=""
CHECKPOINT_FILE="/tmp/otobo-install-checkpoints"
rm -f "$CHECKPOINT_FILE"

checkpoint() { echo "$1" >>"$CHECKPOINT_FILE"; }
have_checkpoint() { grep -q "$1" "$CHECKPOINT_FILE" 2>/dev/null; }
last_checkpoint() { tail -1 "$CHECKPOINT_FILE" 2>/dev/null || echo "none"; }

undo_db() {
	local db_engine="${DB_ENGINE:-mariadb}"
	local db_name="${DB_NAME:-otobo}"
	local db_user="${DB_USER:-otobo}"
	if ! confirm "Drop database '${db_name}' and user '${db_user}'? This cannot be undone."; then
		info "Skipped: DB cleanup for ${db_name}/${db_user}"
		return
	fi
	if [ "$db_engine" = "postgresql" ]; then
		undo_postgresql_db "$db_name" "$db_user"
	else
		undo_mariadb_db "$db_name" "$db_user"
	fi
}

cleanup() {
	local rc=$?
	if [ "$rc" -eq 0 ]; then
		rm -f "$CHECKPOINT_FILE"
		return
	fi
	echo ""
	echo "========================================"
	echo "  Installation Failed — Rolling Back"
	echo "  Last step: $(last_checkpoint)"
	echo "========================================"
	echo ""

	# Walk checkpoints in reverse order (from newest to oldest)
	if have_checkpoint "COMPLETE"; then
		rm -f "$CHECKPOINT_FILE"
		return
	fi

	if have_checkpoint "MONITORING_INSTALLED"; then
		undo_monitoring
	fi
	if have_checkpoint "HARDENING_DONE"; then
		undo_security
	fi
	if have_checkpoint "AI_INSTALLED"; then
		undo_ai
	fi
	if have_checkpoint "WEB_CONFIGURED"; then
		if [ "${WEB_SERVER:-apache}" = "nginx" ]; then
			undo_nginx_install
		else
			undo_apache_install
		fi
	fi
	if have_checkpoint "SSL_CONFIGURED"; then
		undo_ssl
	fi
	if have_checkpoint "WEB_SERVER_INSTALLED"; then
		if [ "${WEB_SERVER:-apache}" = "nginx" ]; then
			systemctl stop otobo-starman 2>/dev/null || true
			pkg_remove nginx 2>/dev/null || true
		else
			pkg_remove apache2 2>/dev/null || true
		fi
	fi
	if have_checkpoint "ADMIN_CONFIGURED"; then
		info "OTOBO admin user may need manual removal via Console.pl"
	fi
	if have_checkpoint "CODE_EXTRACTED"; then
		if confirm "Remove extracted OTOBO code at ${OTOBO_ROOT:-/opt/otobo}?"; then
			undo_otobo_install "${OTOBO_ROOT:-/opt/otobo}"
		else
			info "Skipped: OTOBO code left at ${OTOBO_ROOT:-/opt/otobo}"
		fi
	fi
	if have_checkpoint "PERL_DEPS"; then
		info "Perl packages remain installed (safe to keep)"
	fi
	if have_checkpoint "DB_CREATED"; then
		undo_db
	fi

	warning "Rollback complete. Some items may need manual attention (see above)."
	rm -f "$CHECKPOINT_FILE"
}

trap cleanup EXIT

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
		--apt-repo)
			if [[ -n "${2:-}" ]]; then
				APT_REPO_URL="$2"
				shift 2
			else
				die "Missing URL after --apt-repo"
			fi
			;;
		--apt-gpg-key)
			if [[ -n "${2:-}" ]]; then
				APT_REPO_GPG_KEY_URL="$2"
				shift 2
			else
				die "Missing URL after --apt-gpg-key"
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
		echo "    1) MiniLM (all-MiniLM-L6-v2) - ~80MB, CPU, fastest"
		echo "    2) DistilBERT (distilbert-base-uncased) - ~260MB, good accuracy"
		echo "    3) BERT (bert-base-uncased) - ~440MB, more accurate"
		echo "    4) RoBERTa (roberta-base) - ~500MB, best accuracy"
		echo "    5) Skip model download (download later)"
		echo "========================================"
		local model_choice
		read -r -p "Select model [1]: " model_choice
		case "${model_choice:-1}" in
		1) AI_MODEL="minilm" ;;
		2) AI_MODEL="distilbert" ;;
		3) AI_MODEL="bert" ;;
		4) AI_MODEL="roberta" ;;
		5) AI_MODEL="skip" ;;
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
echo "  OTOBOSuite - OTOBO 11 Installation"
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

run_system_checks

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
echo "  Hardening:      ${INSTALL_HARDENING:-no}"
echo "  Monitoring:     ${INSTALL_MONITORING:-no}"
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
checkpoint "DB_CREATED"

# 2. Install Perl dependencies
install_perl_deps "$DB_ENGINE"
checkpoint "PERL_DEPS"

# 3. Install OTOBO
if [ -n "$APT_REPO_URL" ]; then
	info "Installing OTOBO from apt repository: $APT_REPO_URL"
	apt_repo_install_otobo "$APT_REPO_URL" "$APT_REPO_GPG_KEY_URL"
	register_result "OTOBO Install" "OK" "OTOBO installed via apt from $APT_REPO_URL"
else
	install_otobo "${OTOBO_ROOT:-/opt/otobo}" "${OTOBO_USER:-otobo}" "${OTOBO_GROUP:-www-data}"
fi
configure_otobo_db "$DB_ENGINE" "${DB_HOST:-127.0.0.1}" "$DB_PORT" "$DB_NAME" "$DB_USER" "$DB_PASS"
run_otobo_installer "${OTOBO_ROOT:-/opt/otobo}" "${OTOBO_USER:-otobo}"
checkpoint "CODE_EXTRACTED"

# 4. Configure admin user
configure_otobo_admin_user "${OTOBO_ROOT:-/opt/otobo}" "${OTOBO_USER:-otobo}" "$ADMIN_USER" "$ADMIN_PASS" "$ADMIN_EMAIL"
checkpoint "ADMIN_CONFIGURED"

# 5. Install web server
dispatch_web_server_install "$WEB_SERVER"
checkpoint "WEB_SERVER_INSTALLED"

# 6. SSL
if [ "$SSL_MODE" != "none" ]; then
	configure_ssl "$SSL_MODE"
fi
checkpoint "SSL_CONFIGURED"

# 7. Configure web server
configure_web_server "$WEB_SERVER" "$FQDN" "${OTOBO_ROOT:-/opt/otobo}" "$SSL_MODE"
checkpoint "WEB_CONFIGURED"

# 8. AI module
if [ "$INSTALL_AI" = "yes" ]; then
	# shellcheck source=lib/ai.sh
	source "$SCRIPT_DIR/lib/ai.sh"
	API_PASS=$(openssl rand -base64 24)
	install_ai_module "${OTOBO_ROOT:-/opt/otobo}" "${OTOBO_USER:-otobo}" "$FQDN" "$API_PASS" "$AI_MODEL" "$AI_QUEUE" "$AI_POLL_INTERVAL"
fi
checkpoint "AI_INSTALLED"

# 9. Security hardening
if [ "${INSTALL_HARDENING:-no}" = "yes" ]; then
	run_security_hardening
fi
checkpoint "HARDENING_DONE"

# 10. Monitoring
if [ "${INSTALL_MONITORING:-no}" = "yes" ]; then
	# shellcheck source=lib/monitoring.sh
	source "$SCRIPT_DIR/lib/monitoring.sh"
	install_monitoring_stack
fi
checkpoint "MONITORING_INSTALLED"

# 11. Backup setup
ensure_backup_dir
checkpoint "BACKUP_SETUP"

validation_summary || die "Installation completed with errors"
checkpoint "COMPLETE"

echo ""
echo "========================================"
echo "  OTOBO 11 Installation Complete!"
echo "========================================"
echo "  URL:      http://${FQDN}/otobo"
echo "  Admin:    $ADMIN_USER"
echo "========================================"
