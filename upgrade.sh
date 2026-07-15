#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"
# shellcheck source=lib/otobo.sh
source "$SCRIPT_DIR/lib/otobo.sh"
# shellcheck source=lib/permissions.sh
source "$SCRIPT_DIR/lib/permissions.sh"
# shellcheck source=lib/deb.sh
source "$SCRIPT_DIR/lib/deb.sh"
# shellcheck source=lib/apt_repo.sh
source "$SCRIPT_DIR/lib/apt_repo.sh"

# shellcheck disable=SC2119
load_config

UPGRADE_VERSION=""
CHECK_ONLY=0
DOWNLOAD_URL=""
UPGRADE_APT=0

usage() {
	echo "Usage: $0 [version] [--check] [--latest] [--from-url URL] [--apt]"
	echo ""
	echo "  version       Target OTOBO version (e.g. 11.0.2)"
	echo "  --check       Dry-run — only report versions, no changes"
	echo "  --latest      Fetch the latest 11.x release"
	echo "  --from-url    Download tarball from custom URL"
	echo "  --apt         Upgrade via apt repository instead of tarball"
	exit 1
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--check) CHECK_ONLY=1 ;;
	--latest) UPGRADE_VERSION="latest" ;;
	--from-url)
		shift
		DOWNLOAD_URL="$1"
		;;
	--apt) UPGRADE_APT=1 ;;
	--help | -h) usage ;;
	-*) die "Unknown option: $1" ;;
	*) UPGRADE_VERSION="$1" ;;
	esac
	shift
done

echo ""
echo "========================================"
echo "  OTOBO 11 Upgrade"
echo "========================================"

OTOBO_ROOT="${OTOBO_ROOT:-/opt/otobo}"
OTOBO_USER="${OTOBO_USER:-otobo}"
OTOBO_GROUP="${OTOBO_GROUP:-www-data}"
BACKUP_ROOT="${OTOBO_ROOT}.bak.$(date +%Y%m%d-%H%M%S)"

# -------------------------------------------------
# Version Detection
# -------------------------------------------------

current_version() {
	local release_file="$OTOBO_ROOT/RELEASE"
	local ver=""
	if [ -f "$release_file" ]; then
		ver=$(grep -E '^VERSION' "$release_file" 2>/dev/null | head -1 | sed 's/.*=//;s/[" ]//g')
	fi
	if [ -z "$ver" ] && [ -f "$OTOBO_ROOT/Kernel/Config.pm" ]; then
		ver=$(perl -ne 'print $1 if /\$Self->\{Version\}\s*=\s*'\''([^'\'']+)/' "$OTOBO_ROOT/Kernel/Config.pm" 2>/dev/null)
	fi
	echo "${ver:-unknown}"
}

resolve_target_version() {
	if [ -n "$UPGRADE_VERSION" ]; then
		return
	fi
	echo ""
	echo "Enter the target OTOBO version (e.g. 11.0.2)"
	echo "or 'latest' for the latest 11.x release."
	read -rp "Version [latest]: " input
	UPGRADE_VERSION="${input:-latest}"
}

build_download_url() {
	if [ -n "$DOWNLOAD_URL" ]; then
		return
	fi
	if [ "$UPGRADE_VERSION" = "latest" ]; then
		DOWNLOAD_URL="https://otobo.io/downloads/otobo-latest-11.0.tar.gz"
	else
		DOWNLOAD_URL="https://otobo.io/downloads/otobo-${UPGRADE_VERSION}.tar.gz"
	fi
}

# -------------------------------------------------
# Pre-flight
# -------------------------------------------------

if [ ! -d "$OTOBO_ROOT" ]; then
	die "OTOBO not found at $OTOBO_ROOT"
fi

CV=$(current_version)
info "Current OTOBO version: $CV"

resolve_target_version
build_download_url

if [ "$UPGRADE_VERSION" = "latest" ]; then
	info "Target: latest 11.x release"
else
	info "Target: OTOBO $UPGRADE_VERSION"
fi
info "Download URL: $DOWNLOAD_URL"

# -------------------------------------------------
# Check-only mode
# -------------------------------------------------

if [ "$CHECK_ONLY" -eq 1 ]; then
	info "Dry-run mode — no changes made"
	echo ""
	echo "  Current version: $CV"
	echo "  Download URL:    $DOWNLOAD_URL"
	echo "  Backup path:     $BACKUP_ROOT"
	echo ""
	if curl -sI "$DOWNLOAD_URL" 2>/dev/null | head -1 | grep -q "200\|302\|Found"; then
		success "Download URL is reachable."
	else
		warn "Download URL may not be reachable."
	fi
	exit 0
fi

# -------------------------------------------------
# Confirmation
# -------------------------------------------------

echo ""
echo "  This will:"
echo "    1. Stop OTOBO services"
echo "    2. Full backup (DB + files)"
if [ "$UPGRADE_APT" -eq 1 ]; then
	echo "    3. Upgrade OTOBO package via apt"
else
	echo "    3. Download OTOBO $UPGRADE_VERSION"
	echo "    4. Back up current code to $BACKUP_ROOT"
	echo "    5. Deploy new code, preserving configs"
fi
echo "    6. Re-check Perl dependencies"
echo "    7. Run database upgrade"
echo "    8. Restart services"
echo ""

if ! prompt_yes_no "Proceed with upgrade from v${CV}?" "y"; then
	echo "Upgrade cancelled."
	exit 0
fi

# -------------------------------------------------
# Step 1: Stop services
# -------------------------------------------------

stop_otobo_services() {
	info "Stopping OTOBO services..."

	systemctl stop otobo-starman 2>/dev/null || true
	systemctl stop open-ticket-ai.service 2>/dev/null || true

	if systemctl is-enabled apache2 2>/dev/null | grep -q enabled; then
		systemctl stop apache2 2>/dev/null || true
	fi
	if systemctl is-enabled nginx 2>/dev/null | grep -q enabled; then
		systemctl stop nginx 2>/dev/null || true
	fi

	register_result "Services" "OK" "Services stopped"
	success "Services stopped."
}

# -------------------------------------------------
# Step 2: Full backup
# -------------------------------------------------

run_backup() {
	# shellcheck source=lib/backup.sh
	source "$SCRIPT_DIR/lib/backup.sh"
	backup_full
}

# -------------------------------------------------
# Step 3: Download tarball
# -------------------------------------------------

download_tarball() {
	local tarball_name
	tarball_name=$(basename "$DOWNLOAD_URL")
	local local_path="/tmp/${tarball_name}"

	if [ -f "$local_path" ]; then
		info "Tarball already exists at $local_path"
		echo "$local_path"
		return
	fi

	info "Downloading $DOWNLOAD_URL..."
	wget -q "$DOWNLOAD_URL" -O "$local_path" || die "Failed to download OTOBO from $DOWNLOAD_URL"
	success "Downloaded to $local_path"
	echo "$local_path"
}

# -------------------------------------------------
# Step 4: Preserve configs from current install
# -------------------------------------------------

preserve_configs() {
	local preserve_dir="/tmp/otobo-upgrade-preserve-$$"
	mkdir -p "$preserve_dir"

	if [ -f "$OTOBO_ROOT/Kernel/Config.pm" ]; then
		cp "$OTOBO_ROOT/Kernel/Config.pm" "$preserve_dir/"
		info "Preserved Kernel/Config.pm"
	fi
	if [ -d "$OTOBO_ROOT/Kernel/Config/Files" ]; then
		cp -r "$OTOBO_ROOT/Kernel/Config/Files" "$preserve_dir/" 2>/dev/null || true
		info "Preserved Kernel/Config/Files/"
	fi
	if [ -f /root/.otobo_db_credentials ]; then
		cp /root/.otobo_db_credentials "$preserve_dir/"
		info "Preserved DB credentials"
	fi
	cp "$OTOBO_ROOT/RELEASE" "$preserve_dir/" 2>/dev/null || true

	echo "$preserve_dir"
}

# -------------------------------------------------
# Step 5: Back up current code
# -------------------------------------------------

backup_code() {
	info "Backing up current OTOBO code to $BACKUP_ROOT..."
	if ! mv "$OTOBO_ROOT" "$BACKUP_ROOT"; then
		die "Failed to back up current code to $BACKUP_ROOT"
	fi
	register_result "CodeBackup" "OK" "Current code moved to $BACKUP_ROOT"
	success "Code backed up: $BACKUP_ROOT"
}

# -------------------------------------------------
# Step 6: Deploy new code
# -------------------------------------------------

deploy_new_code() {
	local tarball="$1"
	local preserve_dir="$2"
	local tmp_extract="/tmp/otobo-upgrade-extract-$$"
	local extracted_dir=""

	info "Extracting new OTOBO code..."
	mkdir -p "$tmp_extract"
	tar xzf "$tarball" -C "$tmp_extract"

	extracted_dir=$(find "$tmp_extract" -maxdepth 1 -type d -name "otobo-*" 2>/dev/null | head -1)
	if [ -z "$extracted_dir" ]; then
		extracted_dir=$(find "$tmp_extract" -maxdepth 1 -type d ! -name "." 2>/dev/null | head -1)
	fi

	if [ -z "$extracted_dir" ] || [ ! -d "$extracted_dir" ]; then
		rm -rf "$tmp_extract"
		die "Could not find extracted OTOBO directory in $tmp_extract"
	fi

	info "Deploying new code to $OTOBO_ROOT..."
	mv "$extracted_dir" "$OTOBO_ROOT"

	if [ -f "$preserve_dir/Config.pm" ]; then
		cp "$preserve_dir/Config.pm" "$OTOBO_ROOT/Kernel/Config.pm"
		info "Restored Kernel/Config.pm"
	fi
	if [ -d "$preserve_dir/Files" ]; then
		cp -r "$preserve_dir/Files" "$OTOBO_ROOT/Kernel/Config/" 2>/dev/null || true
		info "Restored Kernel/Config/Files/"
	fi
	if [ -f "$preserve_dir/.otobo_db_credentials" ]; then
		cp "$preserve_dir/.otobo_db_credentials" /root/.otobo_db_credentials
	fi

	rm -rf "$tmp_extract" "$preserve_dir"
	register_result "Deploy" "OK" "New code deployed to $OTOBO_ROOT"
	success "New code deployed."
}

# -------------------------------------------------
# Step 7: Set permissions
# -------------------------------------------------

fix_permissions() {
	set_otobo_permissions "$OTOBO_ROOT" "$OTOBO_USER" "$OTOBO_GROUP"
	register_result "Permissions" "OK" "Permissions set"
}

# -------------------------------------------------
# Step 8: Re-check Perl deps
# -------------------------------------------------

check_perl_deps() {
	info "Checking Perl dependencies..."
	cd "$OTOBO_ROOT" || die "Cannot cd to $OTOBO_ROOT"
	sudo -u "$OTOBO_USER" perl bin/otobo.CheckModules.pl || warn "Some Perl modules missing"
	register_result "PerlDeps" "OK" "Perl dependencies checked"
	success "Perl dependencies checked."
}

# -------------------------------------------------
# Step 9: Run DB migration
# -------------------------------------------------

run_db_upgrade() {
	info "Running database upgrade..."
	cd "$OTOBO_ROOT" || die "Cannot cd to $OTOBO_ROOT"
	sudo -u "$OTOBO_USER" perl bin/otobo.Console.pl Maint::Database::Upgrade || warn "DB upgrade had issues"
	sudo -u "$OTOBO_USER" perl bin/otobo.Console.pl Maint::Cache::Delete || warn "Cache clear had issues"
	register_result "DBUpgrade" "OK" "Database upgrade completed"
	success "Database upgrade completed."
}

# -------------------------------------------------
# Step 10: Restart services
# -------------------------------------------------

restart_otobo_services() {
	info "Restarting services..."

	systemctl daemon-reload 2>/dev/null || true

	if systemctl is-enabled mariadb 2>/dev/null | grep -q enabled; then
		systemctl restart mariadb 2>/dev/null || true
	fi

	systemctl restart otobo-starman 2>/dev/null || true
	systemctl restart open-ticket-ai.service 2>/dev/null || true

	if systemctl is-enabled apache2 2>/dev/null | grep -q enabled; then
		systemctl restart apache2 2>/dev/null || true
	fi
	if systemctl is-enabled nginx 2>/dev/null | grep -q enabled; then
		systemctl restart nginx 2>/dev/null || true
	fi

	register_result "Services" "OK" "Services restarted"
	success "Services restarted."
}

# -------------------------------------------------
# Step 11: Verify
# -------------------------------------------------

verify_upgrade() {
	info "Verifying upgrade..."

	cd "$OTOBO_ROOT" || die "Cannot cd to $OTOBO_ROOT"
	sudo -u "$OTOBO_USER" perl bin/otobo.Console.pl Maint::Database::Check || warn "DB check had issues"

	local new_ver
	new_ver=$(current_version)
	register_result "Version" "OK" "Upgraded to v${new_ver}"
	success "Upgraded from v${CV} to v${new_ver}"
}

# -------------------------------------------------
# Cleanup on failure
# -------------------------------------------------

SAVED_PRESERVE_DIR=""

upgrade_cleanup() {
	local rc=$?
	if [ "$rc" -eq 0 ]; then
		[ -n "$SAVED_PRESERVE_DIR" ] && rm -rf "$SAVED_PRESERVE_DIR"
		return
	fi
	warn "Upgrade failed at step: $UPGRADE_STEP"
	restart_otobo_services
	[ -n "$SAVED_PRESERVE_DIR" ] && rm -rf "$SAVED_PRESERVE_DIR"
}

trap upgrade_cleanup EXIT
UPGRADE_STEP="pre-flight"

# -------------------------------------------------
# Main Upgrade Flow
# -------------------------------------------------

UPGRADE_STEP="stop-services"
stop_otobo_services

UPGRADE_STEP="backup"
run_backup

if [ "$UPGRADE_APT" -eq 1 ]; then
	info "Upgrading OTOBO via apt..."
	# shellcheck disable=SC2119
	apt_repo_upgrade_otobo
else
	UPGRADE_STEP="download"
	TARBALL=$(download_tarball)

	UPGRADE_STEP="preserve-configs"
	PRESERVE=$(preserve_configs)
	SAVED_PRESERVE_DIR="$PRESERVE"

	UPGRADE_STEP="backup-code"
	backup_code

	UPGRADE_STEP="deploy"
	deploy_new_code "$TARBALL" "$PRESERVE"
fi

UPGRADE_STEP="permissions"
fix_permissions
check_perl_deps
run_db_upgrade
restart_otobo_services
verify_upgrade

register_result "Upgrade" "OK" "OTOBO upgraded successfully"
validation_summary || die "Upgrade completed with errors"

echo ""
echo "========================================"
echo "  Upgrade Complete"
echo "========================================"
echo "  From:           v${CV}"
echo "  To:             ${UPGRADE_VERSION}"
echo "  Code backup:    ${BACKUP_ROOT}"
echo "========================================"
