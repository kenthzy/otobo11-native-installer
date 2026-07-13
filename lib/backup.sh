#!/usr/bin/env bash

#############################################
# OTOBOSuite - OTOBO Management Suite
# Automated Backup Module
#############################################

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/functions.sh"

CREDS_FILE="/root/.otobo_db_credentials"
BACKUP_NAMES=()
BACKUP_STATUSES=()
BACKUP_MESSAGES=()
HAS_FAIL=0

register_result() {
    local name="$1"
    local status="$2"
    local message="$3"
    BACKUP_NAMES+=("$name")
    BACKUP_STATUSES+=("$status")
    BACKUP_MESSAGES+=("$message")
    if [[ "$status" == "FAIL" ]]; then
        HAS_FAIL=1
    fi
}

backup_summary() {
    local pass_count=0 warn_count=0 fail_count=0 info_count=0 skip_count=0

    for status in "${BACKUP_STATUSES[@]}"; do
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
    echo -e "${BOLD}$(printf '%*s' 28 "")BACKUP SUMMARY${NC}"
    echo -e "${BOLD}============================================================${NC}"

    for i in "${!BACKUP_NAMES[@]}"; do
        local name="${BACKUP_NAMES[$i]}"
        local status="${BACKUP_STATUSES[$i]}"
        local message="${BACKUP_MESSAGES[$i]}"
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

check_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        error "This script must be run as root (sudo)."
    fi
}

load_db_credentials() {
    OTOBO_DB_NAME="otobo"
    OTOBO_DB_USER="otobo"
    OTOBO_DB_PASSWORD=""

    if [[ -f "$CREDS_FILE" ]]; then
        source "$CREDS_FILE"
    fi
}

discover_otobo_dir() {
    if [[ -d "/opt/otobo" ]]; then
        OTOBO_DIR="/opt/otobo"
    elif [[ -d "/opt/otobo" ]]; then
        OTOBO_DIR="/opt/otobo"
    else
        OTOBO_DIR=""
    fi
}

set_backup_dest() {
    local prefix="$1"
    local timestamp
    timestamp=$(date +"%Y%m%d_%H%M%S")
    BACKUP_DEST="/var/backups/otobo/${prefix}/${timestamp}"
}

ensure_backup_dir() {
    mkdir -p "$BACKUP_DEST"
}

backup_configs() {
    local src_dir

    if [[ -z "$OTOBO_DIR" ]]; then
        register_result "Configs" "SKIP" "OTOBO directory not found"
        warning "OTOBO not installed. Skipping config backup."
        return 1
    fi

    src_dir="$OTOBO_DIR/Kernel"

    if [[ -f "$src_dir/Config.pm" ]]; then
        cp "$src_dir/Config.pm" "$BACKUP_DEST/Config.pm"
        register_result "Config.pm" "PASS" "Backed up to $BACKUP_DEST/Config.pm"
    else
        register_result "Config.pm" "SKIP" "Config.pm not found"
    fi

    if [[ -d "$src_dir/Config/Files" ]]; then
        cp -r "$src_dir/Config/Files" "$BACKUP_DEST/"
        register_result "ConfigFiles" "PASS" "Backed up to $BACKUP_DEST/Files/"
    else
        register_result "ConfigFiles" "SKIP" "Config/Files/ not found"
    fi

    if [[ -f "/root/.otobo_db_credentials" ]]; then
        cp "/root/.otobo_db_credentials" "$BACKUP_DEST/"
        register_result "Credentials" "PASS" "Credentials backed up"
    fi
}

backup_database() {
    local db_pass="${OTOBO_DB_PASSWORD:-}"
    local db_user="${OTOBO_DB_USER:-otobo}"
    local db_name="${OTOBO_DB_NAME:-otobo}"
    local engine="${DB_ENGINE:-mariadb}"

    if [[ "$engine" == "postgresql" ]]; then
        if ! command -v pg_dump >/dev/null 2>&1; then
            register_result "Database" "SKIP" "pg_dump not available"
            warning "PostgreSQL client not installed. Skipping database backup."
            return 1
        fi
        if [[ -n "$db_pass" ]]; then
            PGPASSWORD="$db_pass" pg_dump -U "$db_user" -h localhost "$db_name" >"$BACKUP_DEST/otobo-db.sql" 2>/dev/null
        else
            pg_dump "$db_name" >"$BACKUP_DEST/otobo-db.sql" 2>/dev/null
        fi
    else
        if ! command -v mysqldump >/dev/null 2>&1; then
            register_result "Database" "SKIP" "mysqldump not available"
            warning "MySQL client not installed. Skipping database backup."
            return 1
        fi
        if [[ -n "$db_pass" ]]; then
            mysqldump -u "$db_user" -p"$db_pass" "$db_name" >"$BACKUP_DEST/otobo-db.sql" 2>/dev/null
        else
            mysqldump "$db_name" >"$BACKUP_DEST/otobo-db.sql" 2>/dev/null
        fi
    fi

    if [[ -f "$BACKUP_DEST/otobo-db.sql" ]]; then
        local size
        size=$(du -h "$BACKUP_DEST/otobo-db.sql" | cut -f1)
        register_result "Database" "PASS" "Dumped ($size) to $BACKUP_DEST/otobo-db.sql"
    else
        register_result "Database" "SKIP" "Database not accessible"
        warning "Could not dump database. Check credentials."
    fi
}

backup_articles() {
    local dirs=("var/article" "var/spool" "var/log")

    if [[ -z "$OTOBO_DIR" ]]; then
        register_result "Articles" "SKIP" "OTOBO directory not found"
        return 1
    fi

    local has_any=0
    for rel_dir in "${dirs[@]}"; do
        local full_path="$OTOBO_DIR/$rel_dir"
        if [[ -d "$full_path" ]]; then
            local parent_dir
            parent_dir=$(dirname "$rel_dir")
            mkdir -p "$BACKUP_DEST/$parent_dir"
            cp -r "$full_path" "$BACKUP_DEST/$parent_dir/"
            local size
            size=$(du -sh "$full_path" | cut -f1)
            register_result "$rel_dir" "PASS" "Backed up ($size)"
            has_any=1
        else
            register_result "$rel_dir" "SKIP" "Not found"
        fi
    done

    if [[ "$has_any" -eq 0 ]]; then
        return 1
    fi
    return 0
}

backup_full() {
    info "Running full backup..."
    line
    echo

    discover_otobo_dir
    load_db_credentials
    ensure_backup_dir

    backup_configs
    backup_database
    backup_articles

    local total_size
    total_size=$(du -sh "$BACKUP_DEST" | cut -f1)
    register_result "Total" "PASS" "Backup saved to $BACKUP_DEST (${total_size})"
    success "Full backup complete: $BACKUP_DEST"
}

backup_config_only() {
    info "Running config backup..."
    discover_otobo_dir
    ensure_backup_dir
    backup_configs
    register_result "Total" "PASS" "Configs saved to $BACKUP_DEST"
    success "Config backup complete: $BACKUP_DEST"
}

backup_db_only() {
    info "Running database backup..."
    load_db_credentials
    ensure_backup_dir
    backup_database
    register_result "Total" "PASS" "Database saved to $BACKUP_DEST"
    success "Database backup complete: $BACKUP_DEST"
}

backup_articles_only() {
    info "Running articles backup..."
    discover_otobo_dir
    ensure_backup_dir
    backup_articles
    register_result "Total" "PASS" "Articles saved to $BACKUP_DEST"
    success "Articles backup complete: $BACKUP_DEST"
}

prune_backups() {
    local base="/var/backups/otobo"

    prune_dir() {
        local subdir="$1"
        local keep_days="$2"
        local label="$3"
        local path="$base/$subdir"

        if [[ ! -d "$path" ]]; then
            return
        fi

        local count_before
        count_before=$(find "$path" -maxdepth 1 -type d -name "20*" 2>/dev/null | wc -l)
        find "$path" -maxdepth 1 -type d -name "20*" -mtime "+$keep_days" -exec rm -rf {} + 2>/dev/null
        local count_after
        count_after=$(find "$path" -maxdepth 1 -type d -name "20*" 2>/dev/null | wc -l)
        local removed=$((count_before - count_after))

        if [[ "$removed" -gt 0 ]]; then
            register_result "Prune" "INFO" "Removed $removed old $label backups (kept ${keep_days}d)"
        fi
    }

    prune_dir "daily" 7 "daily"
    prune_dir "weekly" 28 "weekly"
    prune_dir "monthly" 365 "monthly"
}

install_cron() {
    local cron_file="/etc/cron.d/otobo-backup"
    local log_file="/var/log/otobo-backup.log"
    local script_path
    script_path="$(cd "$(dirname "$0")" && pwd)/backup.sh"

    info "Installing daily backup cron job..."

    cat >"$cron_file" <<-EOF
		# OTOBOSuite automatic backup schedule
		# Installed by backup.sh --cron-install
		# Runs daily at 2:30 AM
		SHELL=/bin/bash
		PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
		30 2 * * * root $script_path --cron >> $log_file 2>&1
	EOF

    chmod 644 "$cron_file"

    register_result "CronInstall" "PASS" "Cron job installed: $cron_file"
    success "Daily backup scheduled at 2:30 AM."
    info "Logs: $log_file"

    echo
    info "Would you like to run an initial backup now?"
    if confirm "Run initial backup?" "Y"; then
        echo
        cron_run
    fi
}

cron_run() {
    set_backup_dest "daily"
    backup_full
    prune_backups
}

show_backup_menu() {
    echo " What would you like to back up?"
    echo
    echo "    1) Full backup        -- Configs + database + articles"
    echo "    2) Config only        -- Config.pm, Config/Files/, credentials"
    echo "    3) Database only      -- MySQL dump"
    echo "    4) Articles only      -- var/article, var/spool, var/log"
    echo "    5) Schedule cron      -- Install daily automatic backup"
    echo "    6) Cancel"
    echo
    read -rp " Enter your choice [1-6]: " bm_choice
    echo
}

show_banner() {
    clear
    echo -e "${LIGHT_BLUE}"
    echo "============================================================"
    echo
    echo "                  OTOBOSuite - BACKUP"
    echo
    echo "============================================================"
    echo -e "${NC}"
}

main() {
    check_root

    if [[ "$1" == "--cron" ]]; then
        cron_run
        exit 0
    fi

    if [[ "$1" == "--cron-install" ]]; then
        install_cron
        echo
        backup_summary
        exit 0
    fi

    while true; do
        show_banner
        show_backup_menu

        case "$bm_choice" in
            1)
                line
                set_backup_dest "manual"
                backup_full
                break
                ;;
            2)
                line
                set_backup_dest "manual"
                backup_config_only
                break
                ;;
            3)
                line
                set_backup_dest "manual"
                backup_db_only
                break
                ;;
            4)
                line
                set_backup_dest "manual"
                backup_articles_only
                break
                ;;
            5)
                line
                install_cron
                break
                ;;
            6)
                info "Backup cancelled."
                exit 0
                ;;
            *)
                echo -e "${RED}Invalid choice. Please enter 1-6.${NC}"
                echo
                ;;
        esac
    done

    echo
    backup_summary

    if [[ "$HAS_FAIL" -eq 0 ]]; then
        echo
        success "Backup completed."
    else
        echo
        warning "Backup completed with issues. Check the report above."
    fi
    echo
}

main "$@"
