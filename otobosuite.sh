#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

show_menu() {
	echo ""
	echo "========================================"
	echo "  OTOBOSuite Management Menu"
	echo "========================================"
	echo "  1) Install OTOBO"
	echo "  2) Repair OTOBO"
	echo "  3) Verify OTOBO"
	echo "  4) Uninstall OTOBO"
	echo "  5) Upgrade OTOBO"
	echo "  6) SSL Setup"
	echo "  7) Backup"
	echo "  8) Security"
	echo "  9) Exit"
	echo "========================================"
}

handle_backup_menu() {
	# shellcheck source=lib/backup.sh
	source "$SCRIPT_DIR/lib/backup.sh"
	# shellcheck source=lib/config.sh
	source "$SCRIPT_DIR/lib/config.sh"
	load_config

	echo ""
	echo "========================================"
	echo "  Backup Menu"
	echo "========================================"
	echo "  1) Full backup"
	echo "  2) Partial backup (DB + config)"
	echo "  3) List backups"
	echo "  4) Restore from backup"
	echo "  5) Schedule cron backup"
	echo "  6) Back to main menu"
	echo "========================================"

	local choice
	read -r -p "Select option: " choice
	case "$choice" in
	1)
		do_full_backup "${OTOBO_ROOT:-/opt/otobo}" "${DB_ENGINE:-mariadb}" "${DB_NAME:-otobo}" "${DB_USER:-otobo}" "${DB_PASS:-}"
		;;
	2)
		do_partial_backup "${OTOBO_ROOT:-/opt/otobo}" "${DB_ENGINE:-mariadb}" "${DB_NAME:-otobo}" "${DB_USER:-otobo}" "${DB_PASS:-}"
		;;
	3)
		list_backups
		;;
	4)
		list_backups
		echo ""
		local backup_path
		read -r -p "Enter backup path to restore: " backup_path
		if [ -d "$backup_path" ]; then
			restore_backup "$backup_path" "${OTOBO_ROOT:-/opt/otobo}" "${DB_ENGINE:-mariadb}" "${DB_NAME:-otobo}" "${DB_USER:-otobo}" "${DB_PASS:-}"
		else
			warn "Backup path not found: $backup_path"
		fi
		;;
	5)
		echo "Enter cron schedule (default: daily at 2am):"
		local schedule
		schedule=$(prompt_with_default "Schedule" "0 2 * * *")
		schedule_cron_backup "$schedule" "$SCRIPT_DIR/backup.sh"
		;;
	6) return ;;
	*) warn "Invalid option" ;;
	esac
}

handle_ssl_menu() {
	# shellcheck source=lib/config.sh
	source "$SCRIPT_DIR/lib/config.sh"
	# shellcheck source=lib/ssl.sh
	source "$SCRIPT_DIR/lib/ssl.sh"
	load_config

	echo ""
	echo "========================================"
	echo "  SSL Setup"
	echo "========================================"
	echo "  1) Self-signed certificate"
	echo "  2) Let's Encrypt"
	echo "  3) Back to main menu"
	echo "========================================"

	local choice
	read -r -p "Select option: " choice
	case "$choice" in
	1)
		local fqdn
		fqdn=$(prompt_with_default "FQDN" "${FQDN:-$(hostname -f)}")
		setup_self_signed "$fqdn"
		;;
	2)
		local fqdn email
		fqdn=$(prompt_with_default "FQDN" "${FQDN:-$(hostname -f)}")
		email=$(prompt_with_default "Email" "admin@${fqdn}")
		configure_ssl "${WEB_SERVER:-apache}" "$fqdn" "$email" "letsencrypt"
		;;
	3) return ;;
	*) warn "Invalid option" ;;
	esac
}

handle_security_menu() {
	# shellcheck source=lib/config.sh
	source "$SCRIPT_DIR/lib/config.sh"
	# shellcheck source=lib/firewall.sh
	source "$SCRIPT_DIR/lib/firewall.sh"
	# shellcheck source=lib/security.sh
	source "$SCRIPT_DIR/lib/pkg.sh"
	source "$SCRIPT_DIR/lib/security.sh"
	load_config

	echo ""
	echo "========================================"
	echo "  Security Menu"
	echo "========================================"
	echo "  1) Configure firewall (UFW)"
	echo "  2) Configure fail2ban"
	echo "  3) Configure auto security updates"
	echo "  4) Apply all hardening"
	echo "  5) Back to main menu"
	echo "========================================"

	local choice
	read -r -p "Select option: " choice
	case "$choice" in
	1) configure_ufw_rate_limit ;;
	2) configure_fail2ban ;;
	3) configure_unattended_upgrades ;;
	4) run_security_hardening ;;
	5) return ;;
	*) warn "Invalid option" ;;
	esac
}

# Main loop
while true; do
	show_menu
	choice=""
	read -r -p "Select option: " choice
	case "$choice" in
	1) bash "$SCRIPT_DIR/install.sh" ;;
	2) bash "$SCRIPT_DIR/repair.sh" ;;
	3) bash "$SCRIPT_DIR/verify.sh" ;;
	4) bash "$SCRIPT_DIR/uninstall.sh" ;;
	5) bash "$SCRIPT_DIR/upgrade.sh" ;;
	6) handle_ssl_menu ;;
	7) handle_backup_menu ;;
	8) handle_security_menu ;;
	9)
		echo "Goodbye!"
		exit 0
		;;
	*) warn "Invalid option. Please select 1-9." ;;
	esac
	echo ""
	read -r -p "Press Enter to continue..."
done
