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
	echo "  9) AI Management"
	echo " 10) Migrate OTRS/Znuny to OTOBO"
	echo " 11) Manage APT repository"
	echo " 12) Exit"
	echo "========================================"
}

handle_backup_menu() {
	# shellcheck source=lib/backup.sh
	source "$SCRIPT_DIR/lib/backup.sh"
	# shellcheck source=lib/config.sh
	source "$SCRIPT_DIR/lib/config.sh"
	# shellcheck disable=SC2119
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
	# shellcheck disable=SC2119
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
		configure_ssl "letsencrypt" "$fqdn" "$email"
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
	# shellcheck disable=SC2119
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

handle_repo_menu() {
	echo ""
	echo "========================================"
	echo "  APT Repository Management"
	echo "========================================"
	echo "  1) Build .deb package (latest OTOBO)"
	echo "  2) Initialize a new apt repository"
	echo "  3) Add .deb to repository"
	echo "  4) List repository packages"
	echo "  5) Sign repository"
	echo "  6) Install OTOBO from apt repository"
	echo "  7) Remove OTOBO apt source"
	echo "  8) Back to main menu"
	echo "========================================"

	local choice
	read -r -p "Select option: " choice
	case "$choice" in
	1)
		local ver
		ver=$(prompt_with_default "Version to package" "latest")
		bash "$SCRIPT_DIR/repo-mgr.sh" build-deb "$ver"
		;;
	2)
		local dir codename gpg_key
		dir=$(prompt_with_default "Repository directory" "/var/www/apt-repo")
		codename=$(prompt_with_default "Distribution codename" "$(lsb_release -cs 2>/dev/null || echo 'jammy')")
		read -r -p "GPG key fingerprint (optional): " gpg_key
		bash "$SCRIPT_DIR/repo-mgr.sh" init --repo-dir "$dir" --codename "$codename" ${gpg_key:+--gpg-key "$gpg_key"}
		;;
	3)
		local deb_path repo_dir codename
		read -r -p "Path to .deb file: " deb_path
		repo_dir=$(prompt_with_default "Repository directory" "/var/www/apt-repo")
		codename=$(prompt_with_default "Distribution codename" "$(lsb_release -cs 2>/dev/null || echo 'jammy')")
		if [ -f "$deb_path" ]; then
			bash "$SCRIPT_DIR/repo-mgr.sh" add "$deb_path" --repo-dir "$repo_dir" --codename "$codename"
		else
			warn "File not found: $deb_path"
		fi
		;;
	4)
		local repo_dir
		repo_dir=$(prompt_with_default "Repository directory" "/var/www/apt-repo")
		bash "$SCRIPT_DIR/repo-mgr.sh" list --repo-dir "$repo_dir"
		;;
	5)
		local repo_dir gpg_key
		repo_dir=$(prompt_with_default "Repository directory" "/var/www/apt-repo")
		read -r -p "GPG key fingerprint (optional): " gpg_key
		bash "$SCRIPT_DIR/repo-mgr.sh" sign --repo-dir "$repo_dir" ${gpg_key:+--gpg-key "$gpg_key"}
		;;
	6)
		local repo_url gpg_key_url pkg_ver
		read -r -p "Repository URL (e.g. https://packages.example.com/apt): " repo_url
		read -r -p "GPG key URL (optional): " gpg_key_url
		read -r -p "Package version (optional): " pkg_ver
		bash "$SCRIPT_DIR/repo-mgr.sh" install "$repo_url" ${gpg_key_url:+--gpg-key-url "$gpg_key_url"} ${pkg_ver:+--version "$pkg_ver"}
		;;
	7)
		local src_name
		src_name=$(prompt_with_default "Source name to remove" "otobo")
		bash "$SCRIPT_DIR/repo-mgr.sh" remove "$src_name"
		;;
	8) return ;;
	*) warn "Invalid option" ;;
	esac
}

handle_ai_menu() {
	# shellcheck source=lib/ai.sh
	source "$SCRIPT_DIR/lib/ai.sh"
	# shellcheck source=lib/ai_tune.sh
	source "$SCRIPT_DIR/lib/ai_tune.sh"
	# shellcheck disable=SC2119
	load_config

	echo ""
	echo "========================================"
	echo "  AI Management"
	echo "========================================"
	echo "  1) Fine-tune model on historical tickets"
	echo "  2) View AI dashboard"
	echo "  3) Evaluate model performance"
	echo "  4) Switch active model"
	echo "  5) Restart AI service"
	echo "  6) Back to main menu"
	echo "========================================"

	local choice
	read -r -p "Select option: " choice
	case "$choice" in
	1)
		run_fine_tuning_pipeline "${OTOBO_ROOT:-/opt/otobo}" "${OTOBO_USER:-otobo}"
		;;
	2)
		# shellcheck source=lib/ai_dashboard.sh
		source "$SCRIPT_DIR/lib/ai_dashboard.sh"
		generate_dashboard
		;;
	3)
		evaluate_current_model
		;;
	4)
		switch_model
		;;
	5)
		if systemctl is-enabled open-ticket-ai.service 2>/dev/null | grep -q enabled; then
			systemctl restart open-ticket-ai.service
			info "Open Ticket AI service restarted"
		else
			warn "Open Ticket AI service not found"
		fi
		;;
	6) return ;;
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
	9) handle_ai_menu ;;
	10) bash "$SCRIPT_DIR/migrate.sh" ;;
	11) handle_repo_menu ;;
	12)
		echo "Goodbye!"
		exit 0
		;;
	*) warn "Invalid option. Please select 1-12." ;;
	esac
	echo ""
	read -r -p "Press Enter to continue..."
done
