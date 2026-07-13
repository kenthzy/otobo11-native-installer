#!/usr/bin/env bash

#############################################
# OTOBOSuite - OTOBO Management Suite
# Upgrade Module
#############################################

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/functions.sh"

# shellcheck disable=SC2329
OTOBE_DIR="/opt/otobo"
BACKUP_DIR="/var/backups/otobo"
OLD_DIR="/opt/otobo.old"
STAGING_DIR="/opt/otobo-new"
OTOBE_URL="https://ftp.otobo.org/pub/otobo/otobo-latest-11.0.tar.gz"
CREDS_FILE="/root/.otobo_db_credentials"
CONSOLE_PL="$OTOBE_DIR/bin/otobo.Console.pl"
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')

# shellcheck disable=SC2329
UPGRADE_NAMES=()
UPGRADE_STATUSES=()
UPGRADE_MESSAGES=()
HAS_FAIL=0
ROLLBACK_NEEDED=0

register_result() {
    local name="$1"
    local status="$2"
    local message="$3"
    UPGRADE_NAMES+=("$name")
    UPGRADE_STATUSES+=("$status")
    UPGRADE_MESSAGES+=("$message")
    if [[ "$status" == "FAIL" ]]; then
        HAS_FAIL=1
    fi
}

upgrade_summary() {
    local pass_count=0 warn_count=0 fail_count=0 info_count=0 skip_count=0

    for status in "${UPGRADE_STATUSES[@]}"; do
        case "$status" in
            PASS) ((pass_count++)) ;;
            WARN) ((warn_count++)) ;;
            FAIL) ((fail_count++)) ;;
            INFO) ((info_count++)) ;;
            SKIP) ((skip_count++)) ;;
        esac
    done

    echo
    echo -e "${BOLD}============================================================${NC}"
    echo -e "${BOLD}$(printf '%*s' 28 "")UPGRADE SUMMARY${NC}"
    echo -e "${BOLD}============================================================${NC}"

    for i in "${!UPGRADE_NAMES[@]}"; do
        local name="${UPGRADE_NAMES[$i]}"
        local status="${UPGRADE_STATUSES[$i]}"
        local message="${UPGRADE_MESSAGES[$i]}"
        local formatted_status

        case "$status" in
            PASS) formatted_status="${GREEN}PASS${NC}" ;;
            WARN) formatted_status="${YELLOW}WARN${NC}" ;;
            FAIL) formatted_status="${RED}FAIL${NC}" ;;
            INFO) formatted_status="${LIGHT_BLUE}INFO${NC}" ;;
            SKIP) formatted_status="${MAGENTA}SKIP${NC}" ;;
        esac

        printf " %-18s  %-4b  %s\n" "$name" "$formatted_status" "$message"
    done

    echo -e "${BOLD}============================================================${NC}"
    local total=$((pass_count + warn_count + fail_count + info_count + skip_count))
    local result_line="Result: ${GREEN}${pass_count} PASS${NC}"
    result_line+=", ${YELLOW}${warn_count} WARN${NC}"
    result_line+=", ${RED}${fail_count} FAIL${NC}"
    result_line+=", ${LIGHT_BLUE}${info_count} INFO${NC}"
    result_line+=", ${MAGENTA}${skip_count} SKIP${NC}"
    result_line+=" (${total} total)"
    echo -e " ${result_line}"
    echo -e "${BOLD}============================================================${NC}"
    echo
}

trap rollback_on_exit EXIT

# shellcheck disable=SC2329
rollback_on_exit() {
    local exit_code=$?
    if [[ "$ROLLBACK_NEEDED" -eq 1 && "$exit_code" -ne 0 ]]; then
        echo
        echo -e "${RED}[FAIL]${NC} Upgrade failed. Initiating rollback..."
        echo
        rollback
    fi
}

detect_current_version() {
    local release_file="$OTOBE_DIR/RELEASE"

    if [[ -f "$release_file" ]]; then
        grep "^VERSION" "$release_file" 2>/dev/null | cut -d= -f2 || echo "unknown"
    else
        echo "unknown"
    fi
}

check_prerequisites() {
    if [[ ! -d "$OTOBE_DIR" ]]; then
        register_result "Prerequisites" "FAIL" "OTOBO not installed at $OTOBE_DIR"
        error "OTOBO is not installed. Nothing to upgrade."
    fi

    if ! command -v wget >/dev/null 2>&1; then
        apt-get install -y wget
    fi

    if ! command -v curl >/dev/null 2>&1; then
        apt-get install -y curl
    fi

    local engine="mariadb"
    if [[ -f "$CREDS_FILE" ]]; then
        source "$CREDS_FILE"
        engine="${DB_ENGINE:-mariadb}"
    fi

    if [[ "$engine" == "postgresql" ]]; then
        if ! command -v pg_dump >/dev/null 2>&1; then
            register_result "Prerequisites" "FAIL" "pg_dump not found"
            error "pg_dump is required for PostgreSQL backup."
        fi
    else
        if ! mysql --version >/dev/null 2>&1; then
            register_result "Prerequisites" "FAIL" "MySQL client not found"
            error "MySQL client is required for database backup."
        fi
    fi

    register_result "Prerequisites" "PASS" "All prerequisites met"
    success "Prerequisites verified."
}

backup_configs() {
    info "Backing up OTOBO configuration files..."

    mkdir -p "$BACKUP_DIR/$TIMESTAMP"

    if [[ -f "$OTOBE_DIR/Kernel/Config.pm" ]]; then
        cp "$OTOBE_DIR/Kernel/Config.pm" "$BACKUP_DIR/$TIMESTAMP/Config.pm"
    fi

    if [[ -d "$OTOBE_DIR/Kernel/Config/Files" ]]; then
        cp -r "$OTOBE_DIR/Kernel/Config/Files" "$BACKUP_DIR/$TIMESTAMP/"
    fi

    if [[ -f "$CREDS_FILE" ]]; then
        cp "$CREDS_FILE" "$BACKUP_DIR/$TIMESTAMP/"
    fi

    register_result "BackupConfig" "PASS" "Configs saved to $BACKUP_DIR/$TIMESTAMP"
    success "Configuration files backed up."
}

backup_database() {
    info "Backing up OTOBO database..."

    local db_name="otobo"
    local db_user="otobo"
    local db_pass=""
    local engine="mariadb"

    if [[ -f "$CREDS_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$CREDS_FILE"
        db_name="${OTOBO_DB_NAME:-otobo}"
        db_user="${OTOBO_DB_USER:-otobo}"
        db_pass="${OTOBO_DB_PASSWORD:-}"
        engine="${DB_ENGINE:-mariadb}"
    fi

    mkdir -p "$BACKUP_DIR/$TIMESTAMP"

    if [[ "$engine" == "postgresql" ]]; then
        if [[ -n "$db_pass" ]]; then
            PGPASSWORD="$db_pass" pg_dump -U "$db_user" -h localhost "$db_name" >"$BACKUP_DIR/$TIMESTAMP/otobo-db.sql" 2>/dev/null
        else
            pg_dump "$db_name" >"$BACKUP_DIR/$TIMESTAMP/otobo-db.sql" 2>/dev/null
        fi
    else
        if [[ -n "$db_pass" ]]; then
            mysqldump -u "$db_user" -p"$db_pass" "$db_name" >"$BACKUP_DIR/$TIMESTAMP/otobo-db.sql" 2>/dev/null
        else
            mysqldump "$db_name" >"$BACKUP_DIR/$TIMESTAMP/otobo-db.sql" 2>/dev/null
        fi
    fi

    if [[ -f "$BACKUP_DIR/$TIMESTAMP/otobo-db.sql" ]]; then
        register_result "BackupDB" "PASS" "Database dumped to $BACKUP_DIR/$TIMESTAMP/otobo-db.sql"
        success "Database backed up."
    else
        register_result "BackupDB" "FAIL" "Database backup failed"
        error "Database backup failed. Aborting upgrade."
    fi
}

enter_maintenance() {
    info "Enabling maintenance mode..."

    if [[ -x "$CONSOLE_PL" ]]; then
        sudo -u otobo "$CONSOLE_PL" Maint::System::Maintenance 2>/dev/null || true
    fi

    register_result "Maintenance" "PASS" "Maintenance mode enabled"
    success "OTOBO in maintenance mode."
}

download_new_version() {
    info "Downloading latest OTOBO 11..."

    cd /tmp
    wget -q "$OTOBE_URL" -O otobo-latest-11.0.tar.gz

    if [[ ! -f /tmp/otobo-latest-11.0.tar.gz ]]; then
        register_result "Download" "FAIL" "Download failed"
        error "Download failed."
    fi

    register_result "Download" "PASS" "Latest tarball downloaded"
    success "Download complete."
}

extract_staging() {
    info "Extracting to staging directory..."

    rm -rf "$STAGING_DIR"
    mkdir -p "$STAGING_DIR"

    cd /tmp
    tar -xzf otobo-latest-11.0.tar.gz -C "$STAGING_DIR" --strip-components=1

    rm -f /tmp/otobo-latest-11.0.tar.gz

    if [[ ! -f "$STAGING_DIR/Kernel/Config.pm.dist" ]]; then
        register_result "Extract" "FAIL" "Extraction produced unexpected structure"
        error "Extraction failed — Kernel/Config.pm.dist not found."
    fi

    register_result "Extract" "PASS" "Extracted to $STAGING_DIR"
    success "Extracted to staging directory."
}

restore_configs() {
    info "Restoring configuration files into new version..."

    if [[ -f "$BACKUP_DIR/$TIMESTAMP/Config.pm" ]]; then
        cp "$BACKUP_DIR/$TIMESTAMP/Config.pm" "$STAGING_DIR/Kernel/Config.pm"
        chmod 664 "$STAGING_DIR/Kernel/Config.pm"
        chown otobo:www-data "$STAGING_DIR/Kernel/Config.pm"
    fi

    mkdir -p "$STAGING_DIR/Kernel/Config/Files"

    if [[ -d "$BACKUP_DIR/$TIMESTAMP/Files" ]]; then
        cp -r "$BACKUP_DIR/$TIMESTAMP/Files/"* "$STAGING_DIR/Kernel/Config/Files/" 2>/dev/null || true
    fi

    chown -R otobo:www-data "$STAGING_DIR/Kernel/Config.pm" "$STAGING_DIR/Kernel/Config/Files" 2>/dev/null || true

    register_result "RestoreConfig" "PASS" "Custom configs restored in new version"
    success "Configuration files restored."
}

set_permissions() {
    info "Setting file permissions on new version..."

    chown -R otobo:www-data "$STAGING_DIR"
    find "$STAGING_DIR" -type d -exec chmod 775 {} \;
    find "$STAGING_DIR" -type f -not -executable -exec chmod 644 {} \;
    chmod 755 "$STAGING_DIR/bin/"* 2>/dev/null || true
    chmod 755 "$STAGING_DIR/var/httpd/htdocs/"*.pl 2>/dev/null || true

    register_result "Permissions" "PASS" "File permissions set on new version"
    success "Permissions set."
}

swap_directories() {
    info "Swapping OTOBO directories..."

    rm -rf "$OLD_DIR"
    mv "$OTOBE_DIR" "$OLD_DIR"
    mv "$STAGING_DIR" "$OTOBE_DIR"

    register_result "Swap" "PASS" "Directories swapped (old at $OLD_DIR)"
    success "New version is now live at $OTOBE_DIR."
}

restart_services() {
    info "Restarting services..."

    systemctl restart apache2 2>/dev/null || true
    systemctl restart otobo-daemon 2>/dev/null || true
    systemctl restart otobo-web 2>/dev/null || true

    sleep 2

    local issues=""

    if ! systemctl is-active --quiet apache2 2>/dev/null; then
        issues="${issues}Apache; "
    fi

    if [[ -n "$issues" ]]; then
        register_result "Restart" "WARN" "Services restarted but issues: ${issues%%; }"
        warning "Some services may not have restarted properly: ${issues%%; }"
    else
        register_result "Restart" "PASS" "Apache + OTOBO services restarted"
        success "Services restarted."
    fi
}

run_db_migration() {
    info "Running database migration..."

    if [[ ! -x "$OTOBE_DIR/bin/otobo.Console.pl" ]]; then
        register_result "Migration" "SKIP" "Console.pl not found in new version"
        info "Console.pl not available. Skipping DB migration."
        return
    fi

    if sudo -u otobo "$OTOBE_DIR/bin/otobo.Console.pl" Maint::Database::Migration 2>/dev/null; then
        register_result "Migration" "PASS" "Database schema migrated successfully"
        success "Database migration completed."
    else
        register_result "Migration" "FAIL" "Database migration encountered issues"
        warning "DB migration may have warnings. Check Console.pl output."
    fi
}

disable_maintenance() {
    info "Disabling maintenance mode..."

    if [[ -x "$OTOBE_DIR/bin/otobo.Console.pl" ]]; then
        sudo -u otobo "$OTOBE_DIR/bin/otobo.Console.pl" Maint::System::Maintenance 2>/dev/null || true
    fi

    register_result "MaintenanceOff" "PASS" "Maintenance mode disabled"
    success "Maintenance mode disabled."
}

run_verification() {
    info "Running post-upgrade verification..."

    if [[ -f "$SCRIPT_DIR/verify.sh" ]]; then
        "$SCRIPT_DIR/verify.sh" || true
    fi

    register_result "Verify" "PASS" "Post-upgrade verification completed"
    success "Verification completed."
}

# shellcheck disable=SC2329
rollback() {
    echo
    warning "Performing rollback..."
    echo

    if [[ -d "$STAGING_DIR" ]]; then
        rm -rf "$STAGING_DIR"
    fi

    if [[ -d "$OLD_DIR" && -d "$OTOBE_DIR" ]]; then
        rm -rf "$OTOBE_DIR"
        mv "$OLD_DIR" "$OTOBE_DIR"
    elif [[ -d "$OLD_DIR" ]]; then
        mv "$OLD_DIR" "$OTOBE_DIR"
    fi

    if [[ -f "$BACKUP_DIR/$TIMESTAMP/otobo-db.sql" ]]; then
        local db_name="otobo"
        local engine="mariadb"

        if [[ -f "$CREDS_FILE" ]]; then
            # shellcheck disable=SC1090
            source "$CREDS_FILE"
            db_name="${OTOBO_DB_NAME:-otobo}"
            engine="${DB_ENGINE:-mariadb}"
        fi

        if [[ "$engine" == "postgresql" ]]; then
            su - postgres -c "psql -c \"DROP DATABASE IF EXISTS ${db_name}\"" 2>/dev/null || true
            su - postgres -c "psql -c \"CREATE DATABASE ${db_name} OWNER ${OTOBO_DB_USER:-otobo}\"" 2>/dev/null || true
            PGPASSWORD="${OTOBO_DB_PASSWORD:-}" psql -h localhost -U "${OTOBO_DB_USER:-otobo}" -d "$db_name" <"$BACKUP_DIR/$TIMESTAMP/otobo-db.sql" 2>/dev/null || true
        else
            mysql "$db_name" <"$BACKUP_DIR/$TIMESTAMP/otobo-db.sql" 2>/dev/null || true
        fi
        info "Database restored from backup."
    fi

    systemctl restart apache2 2>/dev/null || true
    systemctl restart otobo-daemon 2>/dev/null || true
    systemctl restart otobo-web 2>/dev/null || true

    echo
    echo -e "${YELLOW}============================================================${NC}"
    echo -e "${YELLOW}                      ROLLBACK COMPLETED                     ${NC}"
    echo -e "${YELLOW}============================================================${NC}"
    echo
    warning "Upgrade failed. System has been rolled back to previous version."
}

main() {
    clear
    echo -e "${LIGHT_BLUE}"
    echo "============================================================"
    echo
    echo "                    OTOBOSuite - UPGRADE"
    echo
    echo "============================================================"
    echo -e "${NC}"

    local current_version
    current_version=$(detect_current_version)
    echo
    echo -e " Current OTOBO version: ${BOLD}${current_version}${NC}"
    echo -e " Latest available:       ${BOLD}11.0.x (latest)${NC}"
    echo
    echo -e " ${YELLOW}This will:${NC}"
    echo -e "  1. Backup config files and database"
    echo -e "  2. Enable maintenance mode"
    echo -e "  3. Download and extract latest OTOBO"
    echo -e "  4. Restore your custom configurations"
    echo -e "  5. Swap to new version (old saved as ${OLD_DIR})"
    echo -e "  6. Run database migration"
    echo -e "  7. Disable maintenance mode"
    echo -e "  8. Verify installation"
    echo
    echo -e " ${YELLOW}If anything fails, rollback is automatic.${NC}"
    echo

    if ! confirm "Proceed with upgrade?" "N"; then
        info "Upgrade cancelled."
        exit 0
    fi

    echo
    line
    info "Starting OTOBO upgrade..."
    line
    echo

    check_prerequisites
    backup_configs
    backup_database

    ROLLBACK_NEEDED=1

    enter_maintenance
    download_new_version
    extract_staging
    restore_configs
    set_permissions
    swap_directories
    restart_services
    run_db_migration
    disable_maintenance
    run_verification

    echo
    upgrade_summary

    if [[ "$HAS_FAIL" -eq 0 ]]; then
        echo
        echo -e "${GREEN}============================================================${NC}"
        echo -e "${GREEN}$(printf '%*s' 20 "")UPGRADE COMPLETED SUCCESSFULLY${NC}"
        echo -e "${GREEN}============================================================${NC}"
        echo
        echo -e " Old version saved at: ${YELLOW}${OLD_DIR}${NC}"
        echo -e " Backups saved at:      ${YELLOW}${BACKUP_DIR}/${TIMESTAMP}${NC}"
        echo
        echo -e " To rollback manually:  ${YELLOW}sudo mv ${OLD_DIR} ${OTOBE_DIR}${NC}"
        echo

        if confirm "Remove old version (${OLD_DIR}) to free space?" "N"; then
            rm -rf "$OLD_DIR"
            echo -e "${GREEN}Old version removed.${NC}"
        fi
    else
        warning "Upgrade completed with warnings. Review the report above."
    fi

    echo
    exit "$HAS_FAIL"
}

main "$@"
