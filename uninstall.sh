#!/usr/bin/env bash

#############################################
# OTOBOSuite - OTOBO Management Suite
# Uninstall Module
#############################################

set -e

source "$(dirname "$0")/lib/colors.sh"
source "$(dirname "$0")/lib/functions.sh"

UNINSTALL_NAMES=()
UNINSTALL_STATUSES=()
UNINSTALL_MESSAGES=()
HAS_FAIL=0
FULL_MODE=0

register_result() {
    local name="$1"
    local status="$2"
    local message="$3"
    UNINSTALL_NAMES+=("$name")
    UNINSTALL_STATUSES+=("$status")
    UNINSTALL_MESSAGES+=("$message")
    if [[ "$status" == "FAIL" ]]; then
        HAS_FAIL=1
    fi
}

uninstall_summary() {
    local pass_count=0 warn_count=0 fail_count=0 info_count=0 skip_count=0

    for status in "${UNINSTALL_STATUSES[@]}"; do
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
    echo -e "${BOLD}$(printf '%*s' 30 "")UNINSTALL SUMMARY${NC}"
    echo -e "${BOLD}============================================================${NC}"

    for i in "${!UNINSTALL_NAMES[@]}"; do
        local name="${UNINSTALL_NAMES[$i]}"
        local status="${UNINSTALL_STATUSES[$i]}"
        local message="${UNINSTALL_MESSAGES[$i]}"
        local formatted_status

        case "$status" in
            PASS) formatted_status="${GREEN}PASS${NC}" ;;
            WARN) formatted_status="${YELLOW}WARN${NC}" ;;
            FAIL) formatted_status="${RED}FAIL${NC}" ;;
            INFO) formatted_status="${LIGHT_BLUE}INFO${NC}" ;;
            SKIP) formatted_status="${MAGENTA}SKIP${NC}" ;;
        esac

        printf " %-16s  %-4b  %s\n" "$name" "$formatted_status" "$message"
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

uninstall_step() {
    local name="$1"
    local desc="$2"
    shift 2

    if [[ "$FULL_MODE" -eq 1 ]] || confirm "  Remove ${desc}?" "N"; then
        info "Removing ${desc}..."
        "$@" || true
        register_result "$name" "PASS" "${desc} removed"
        success "${desc} removed."
    else
        register_result "$name" "SKIP" "${desc} skipped"
        info "${desc} skipped."
    fi
}

remove_otobo_files() {
    if [[ -d /opt/otobo ]]; then
        rm -rf /opt/otobo
        register_result "OTOBOfiles" "PASS" "/opt/otobo removed"
        success "OTOBO files removed."
    else
        register_result "OTOBOfiles" "INFO" "/opt/otobo not found"
        info "OTOBO directory not found. Skipping."
    fi
}

remove_otobo_user() {
    if id otobo >/dev/null 2>&1; then
        userdel -r otobo 2>/dev/null || true
        register_result "OTOBouser" "PASS" "User 'otobo' removed"
        success "OTOBO system user removed."
    else
        register_result "OTOBouser" "INFO" "User 'otobo' not found"
        info "OTOBO user not found. Skipping."
    fi
}

remove_apache_config() {
    if [[ -f /etc/apache2/sites-available/zzz_otobo.conf ]]; then
        a2dissite zzz_otobo >/dev/null 2>&1 || true
        rm -f /etc/apache2/sites-available/zzz_otobo.conf
        rm -f /etc/apache2/sites-enabled/zzz_otobo.conf
        register_result "ApacheSite" "PASS" "zzz_otobo site removed"
        success "OTOBO Apache site removed."
    else
        register_result "ApacheSite" "INFO" "zzz_otobo not found"
        info "OTOBO Apache site not found. Skipping."
    fi

    a2ensite 000-default >/dev/null 2>&1 || true

    if [[ -f /etc/apache2/conf-available/servername.conf ]]; then
        a2disconf servername >/dev/null 2>&1 || true
        rm -f /etc/apache2/conf-available/servername.conf
        register_result "ServerName" "PASS" "servername.conf removed"
    else
        register_result "ServerName" "INFO" "servername.conf not found"
    fi
}

restore_apache_modules() {
    local apache_modules=(perl deflate headers rewrite proxy proxy_http ssl socache_shmcb)

    for mod in "${apache_modules[@]}"; do
        if a2query -m "$mod" >/dev/null 2>&1; then
            a2dismod "$mod" >/dev/null 2>&1 || true
        fi
    done

    if a2query -m mpm_prefork >/dev/null 2>&1; then
        a2dismod mpm_prefork >/dev/null 2>&1 || true
    fi

    if ! a2query -m mpm_event >/dev/null 2>&1; then
        a2enmod mpm_event >/dev/null 2>&1 || true
    fi

    register_result "ApacheMods" "PASS" "Apache modules restored to defaults"
    success "Apache modules restored."
}

remove_systemd_services() {
    local services=(otobo-daemon otobo-web)
    local found=0

    for svc in "${services[@]}"; do
        if [[ -f "/etc/systemd/system/${svc}.service" ]]; then
            systemctl stop "${svc}" >/dev/null 2>&1 || true
            systemctl disable "${svc}" >/dev/null 2>&1 || true
            rm -f "/etc/systemd/system/${svc}.service"
            found=1
        fi
    done

    if [[ "$found" -eq 1 ]]; then
        systemctl daemon-reload
        register_result "Systemd" "PASS" "OTOBO systemd services removed"
        success "OTOBO systemd services removed."
    else
        register_result "Systemd" "INFO" "No OTOBO systemd services found"
        info "No OTOBO systemd services found. Skipping."
    fi
}

remove_database() {
    local creds_file="/root/.otobo_db_credentials"

    if [[ -f "$creds_file" ]]; then
        # shellcheck disable=SC1090
        source "$creds_file"
        mysql -e "DROP DATABASE IF EXISTS ${OTOBO_DB_NAME};" 2>/dev/null || true
        mysql -e "DROP USER IF EXISTS '${OTOBO_DB_USER}'@'${OTOBO_DB_HOST}';" 2>/dev/null || true
        register_result "Database" "PASS" "Database '${OTOBO_DB_NAME}' and user removed"
        success "OTOBO database and user removed."
    else
        mysql -e "DROP DATABASE IF EXISTS otobo;" 2>/dev/null || true
        mysql -e "DROP USER IF EXISTS 'otobo'@'localhost';" 2>/dev/null || true
        register_result "Database" "PASS" "Database 'otobo' and user removed"
        success "OTOBO database and user removed (default names)."
    fi
}

remove_mariadb_config() {
    if [[ -f /etc/mysql/mariadb.conf.d/99-otobo.cnf ]]; then
        rm -f /etc/mysql/mariadb.conf.d/99-otobo.cnf
        systemctl restart mariadb
        register_result "MariaCnf" "PASS" "MariaDB OTOBO config removed"
        success "MariaDB OTOBO config removed."
    else
        register_result "MariaCnf" "INFO" "No MariaDB OTOBO config found"
        info "MariaDB OTOBO config not found. Skipping."
    fi
}

remove_credentials() {
    if [[ -f /root/.otobo_db_credentials ]]; then
        rm -f /root/.otobo_db_credentials
        register_result "Credentials" "PASS" "/root/.otobo_db_credentials removed"
        success "Credentials file removed."
    else
        register_result "Credentials" "INFO" "No credentials file found"
        info "Credentials file not found. Skipping."
    fi
}

remove_firewall_rules() {
    local rules=(80/tcp 443/tcp)
    local found=0

    for rule in "${rules[@]}"; do
        if ufw status | grep -q "$rule"; then
            ufw delete allow "$rule" >/dev/null 2>&1 || true
            found=1
        fi
    done

    if [[ "$found" -eq 1 ]]; then
        register_result "Firewall" "PASS" "HTTP/HTTPS firewall rules removed"
        success "Firewall rules removed."
    else
        register_result "Firewall" "INFO" "No HTTP/HTTPS firewall rules found"
        info "No HTTP/HTTPS firewall rules found. Skipping."
    fi
}

restart_apache() {
    if systemctl is-active --quiet apache2; then
        systemctl restart apache2
        register_result "ApacheRestart" "PASS" "Apache restarted"
        success "Apache restarted."
    else
        register_result "ApacheRestart" "INFO" "Apache not running, skipping restart"
        info "Apache not running. Skipping restart."
    fi
}

main() {
    if [[ "$1" == "--full" || "$1" == "-f" ]]; then
        FULL_MODE=1
    fi

    clear

    echo -e "${LIGHT_BLUE}"
    echo "============================================================"
    echo
    echo "                    OTOBOSuite - UNINSTALL"
    echo
    echo "============================================================"
    echo -e "${NC}"

    if [[ "$FULL_MODE" -eq 0 ]]; then
        echo
        warning "This will remove OTOBO and related components."
        echo
        if ! confirm "Are you sure you want to continue?" "N"; then
            info "Uninstall cancelled."
            exit 0
        fi
        echo
        info "Run with --full to skip individual prompts."
        echo
    fi

    line
    info "Starting uninstall..."
    line
    echo

    if [[ "$FULL_MODE" -eq 1 ]]; then
        remove_otobo_files
        remove_otobo_user
        remove_apache_config
        restore_apache_modules
        remove_systemd_services
        remove_database
        remove_mariadb_config
        remove_credentials
        remove_firewall_rules
        restart_apache
    else
        uninstall_step "OTOBOfiles" "OTOBO files (/opt/otobo)" remove_otobo_files
        uninstall_step "OTOBouser" "system user 'otobo'" remove_otobo_user
        uninstall_step "ApacheSite" "Apache site (zzz_otobo)" remove_apache_config
        uninstall_step "ApacheMods" "Apache OTOBO modules" restore_apache_modules
        uninstall_step "Systemd" "systemd services" remove_systemd_services
        uninstall_step "Database" "MariaDB database + user" remove_database
        uninstall_step "MariaCnf" "MariaDB OTOBO config" remove_mariadb_config
        uninstall_step "Credentials" "credentials file" remove_credentials
        uninstall_step "Firewall" "firewall rules" remove_firewall_rules
        uninstall_step "ApacheRestart" "Apache restart" restart_apache
    fi

    uninstall_summary

    if [[ "$HAS_FAIL" -eq 1 ]]; then
        echo -e "${YELLOW}Some items could not be removed. Check the report above.${NC}"
    else
        echo -e "${GREEN}Uninstall completed.${NC}"
    fi
    echo

    exit "$HAS_FAIL"
}

main "$@"
