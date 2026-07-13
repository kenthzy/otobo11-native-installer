#!/usr/bin/env bash

#############################################
# OTOBOSuite - OTOBO Management Suite
# Post-Installation Verification
# Run: sudo ./verify.sh
#############################################

set -e

source lib/colors.sh
source lib/banner.sh
source lib/functions.sh
source lib/validation.sh

# -------------------------------------------------
# Constants
# -------------------------------------------------

CONFIG_FILE="/opt/otobo/Kernel/Config.pm"
APACHE_SITE="zzz_otobo"

# -------------------------------------------------
# Verification Functions
# -------------------------------------------------

detect_webserver() {
    if command -v nginx >/dev/null 2>&1 && systemctl is-active --quiet nginx 2>/dev/null; then
        echo "nginx"
    elif command -v apache2 >/dev/null 2>&1; then
        echo "apache"
    else
        echo ""
    fi
}

verify_apache() {
    local ws
    ws=$(detect_webserver)

    if [[ "$ws" == "nginx" ]]; then
        verify_nginx
        return
    fi

    info "Verifying Apache..."

    if ! command -v apache2 >/dev/null 2>&1; then
        register_result "Apache" "FAIL" "Apache is not installed"
        warning "Apache is not installed."
        return
    fi

    if ! systemctl is-active --quiet apache2 2>/dev/null; then
        register_result "Apache" "FAIL" "Apache is not running"
        warning "Apache is not running."
        return
    fi

    local issues=""

    if ! a2query -s "$APACHE_SITE" 2>/dev/null | grep -q "enabled"; then
        issues="${issues}OTBO vhost not enabled; "
    fi

    if ! apache2ctl configtest 2>/dev/null; then
        issues="${issues}config syntax error; "
    fi

    if [[ -n "$issues" ]]; then
        register_result "Apache" "WARN" "Running but issues: ${issues%%; }"
        warning "Apache issues: ${issues%%; }"
    else
        register_result "Apache" "PASS" "Running, OTOBO site enabled, config valid"
        success "Apache verified."
    fi
}

verify_nginx() {
    info "Verifying nginx..."

    if ! command -v nginx >/dev/null 2>&1; then
        register_result "Nginx" "FAIL" "nginx is not installed"
        warning "nginx is not installed."
        return
    fi

    if ! systemctl is-active --quiet nginx 2>/dev/null; then
        register_result "Nginx" "FAIL" "nginx is not running"
        warning "nginx is not running."
        return
    fi

    local issues=""

    if [[ ! -f /etc/nginx/sites-available/otobo ]]; then
        issues="${issues}OTBO site config missing; "
    fi

    if ! nginx -t 2>/dev/null; then
        issues="${issues}config syntax error; "
    fi

    if command -v starman >/dev/null 2>&1; then
        if systemctl is-active --quiet otobo-starman 2>/dev/null; then
            register_result "Starman" "PASS" "Starman is running"
        else
            issues="${issues}Starman not running; "
        fi
    fi

    if [[ -n "$issues" ]]; then
        register_result "Nginx" "WARN" "Running but issues: ${issues%%; }"
        warning "nginx issues: ${issues%%; }"
    else
        register_result "Nginx" "PASS" "Running, OTOBO site configured, config valid"
        success "nginx verified."
    fi
}

detect_db_engine() {
    if [[ -f /root/.otobo_db_credentials ]]; then
        source /root/.otobo_db_credentials
        echo "${DB_ENGINE:-mariadb}"
    else
        echo "mariadb"
    fi
}

verify_mariadb() {
    local engine
    engine=$(detect_db_engine)

    if [[ "$engine" == "postgresql" ]]; then
        verify_postgresql
        return
    fi

    info "Verifying MariaDB..."

    if ! command -v mariadb >/dev/null 2>&1 && ! command -v mysql >/dev/null 2>&1; then
        register_result "MariaDB" "FAIL" "MariaDB is not installed"
        warning "MariaDB is not installed."
        return
    fi

    if ! systemctl is-active --quiet mariadb 2>/dev/null; then
        register_result "MariaDB" "FAIL" "MariaDB is not running"
        warning "MariaDB is not running."
        return
    fi

    local issues=""

    if ! mysql -e "USE otobo" 2>/dev/null; then
        issues="${issues}database 'otobo' missing; "
    fi

    if ! mysql -e "SELECT User FROM mysql.user WHERE User='otobo'" 2>/dev/null | grep -q "otobo"; then
        issues="${issues}user 'otobo' missing; "
    fi

    if [[ -n "$issues" ]]; then
        register_result "MariaDB" "WARN" "Running but: ${issues%%; }"
        warning "MariaDB issues: ${issues%%; }"
    else
        register_result "MariaDB" "PASS" "Running, DB 'otobo' and user exist"
        success "MariaDB verified."
    fi
}

verify_postgresql() {
    info "Verifying PostgreSQL..."

    if ! command -v psql >/dev/null 2>&1; then
        register_result "PostgreSQL" "FAIL" "PostgreSQL is not installed"
        warning "PostgreSQL is not installed."
        return
    fi

    if ! systemctl is-active --quiet postgresql 2>/dev/null; then
        register_result "PostgreSQL" "FAIL" "PostgreSQL is not running"
        warning "PostgreSQL is not running."
        return
    fi

    local issues=""

    if ! su - postgres -c "psql -lqt 2>/dev/null" | cut -d \| -f 1 | grep -qw "otobo"; then
        issues="${issues}database 'otobo' missing; "
    fi

    if ! su - postgres -c "psql -t -c \"SELECT 1 FROM pg_roles WHERE rolname='otobo'\"" 2>/dev/null | grep -q 1; then
        issues="${issues}user 'otobo' missing; "
    fi

    if [[ -n "$issues" ]]; then
        register_result "PostgreSQL" "WARN" "Running but: ${issues%%; }"
        warning "PostgreSQL issues: ${issues%%; }"
    else
        register_result "PostgreSQL" "PASS" "Running, DB 'otobo' and user exist"
        success "PostgreSQL verified."
    fi
}

verify_perl() {
    info "Verifying Perl..."

    if ! command -v perl >/dev/null 2>&1; then
        register_result "Perl" "FAIL" "Perl is not installed"
        warning "Perl is not installed."
        return
    fi

    local perl_version
    perl_version=$(perl -e 'print $^V')

    register_result "Perl" "PASS" "Installed (${perl_version})"
    success "Perl ${perl_version}."

    local check_script="/opt/otobo/bin/otobo.CheckModules.pl"

    if [[ ! -x "$check_script" ]]; then
        register_result "PerlModules" "INFO" "Module check script not available"
        info "OTBO module checker not found. Skipping module check."
        return
    fi

    if "$check_script" --list >/dev/null 2>&1; then
        register_result "PerlModules" "PASS" "All required Perl modules present"
        success "All required Perl modules installed."
    else
        register_result "PerlModules" "WARN" "Some Perl modules are missing"
        warning "Some Perl modules are missing. Run /opt/otobo/bin/otobo.CheckModules.pl --list"
    fi
}

verify_otobo() {
    info "Verifying OTOBO installation..."

    if [[ ! -d /opt/otobo ]]; then
        register_result "OTOBO" "FAIL" "/opt/otobo does not exist"
        warning "OTOBO is not installed."
        return
    fi

    local issues=""

    if [[ ! -f "$CONFIG_FILE" ]]; then
        issues="${issues}Kernel/Config.pm missing; "
    fi

    if [[ -z "$issues" ]]; then
        if ! perl -c "$CONFIG_FILE" >/dev/null 2>&1; then
            issues="${issues}Config.pm has syntax errors; "
        fi
    fi

    if [[ -n "$issues" ]]; then
        register_result "OTOBO" "WARN" "Installed but: ${issues%%; }"
        warning "OTOBO issues: ${issues%%; }"
    else
        register_result "OTOBO" "PASS" "/opt/otobo present, Config.pm valid"
        success "OTOBO installation verified."
    fi
}

verify_database() {
    info "Verifying database connection..."

    if [[ ! -f "$CONFIG_FILE" ]]; then
        register_result "Database" "SKIP" "Config.pm not found"
        info "Config.pm not found. Skipping database verification."
        return
    fi

    local db_host
    local db_user
    local db_pw
    local dsn

    # shellcheck disable=SC2016
    db_host=$(perl -ne 'print $1 if /\$Self->\{DatabaseHost\}\s*=\s*'\''([^'\'']+)/' "$CONFIG_FILE")
    # shellcheck disable=SC2016
    db_user=$(perl -ne 'print $1 if /\$Self->\{DatabaseUser\}\s*=\s*'\''([^'\'']+)/' "$CONFIG_FILE")
    # shellcheck disable=SC2016
    db_pw=$(perl -ne 'print $1 if /\$Self->\{DatabasePw\}\s*=\s*'\''([^'\'']+)/' "$CONFIG_FILE")
    # shellcheck disable=SC2016
    dsn=$(perl -ne 'print $1 if /\$Self->\{DatabaseDSN\}\s*=\s*'\''([^'\'']+)/' "$CONFIG_FILE")

    db_host="${db_host:-localhost}"
    db_user="${db_user:-otobo}"

    if [[ -z "$db_pw" || "$db_pw" == "some-pass" ]]; then
        register_result "Database" "WARN" "Password not set or still default"
        warning "Database password is not configured."
        return
    fi

    if echo "$dsn" | grep -q "^DBI:Pg:"; then
        if PGPASSWORD="$db_pw" psql -h "$db_host" -U "$db_user" -d otobo -c "SELECT 1" >/dev/null 2>&1; then
            register_result "Database" "PASS" "Connection successful (PostgreSQL)"
            success "Database connection verified."
        else
            register_result "Database" "FAIL" "Cannot connect using Config.pm credentials"
            warning "Database connection failed."
        fi
    else
        if mysql -u "$db_user" -p"$db_pw" -h "$db_host" -e "SELECT 1" >/dev/null 2>&1; then
            register_result "Database" "PASS" "Connection successful"
            success "Database connection verified."
        else
            register_result "Database" "FAIL" "Cannot connect using Config.pm credentials"
            warning "Database connection failed."
        fi
    fi
}

verify_permissions() {
    info "Verifying file permissions..."

    if [[ ! -d /opt/otobo ]]; then
        register_result "Permissions" "SKIP" "/opt/otobo does not exist"
        info "OTOBO not installed. Skipping permissions check."
        return
    fi

    local owner
    owner=$(stat -c '%U:%G' /opt/otobo 2>/dev/null || stat -f '%Su:%Sg' /opt/otobo 2>/dev/null)

    if [[ "$owner" == "otobo:www-data" ]]; then
        register_result "Permissions" "PASS" "Ownership: otobo:www-data"
        success "File permissions verified."
    else
        register_result "Permissions" "WARN" "Ownership is ${owner} (expected otobo:www-data)"
        warning "Ownership is ${owner}, expected otobo:www-data."
    fi
}

verify_firewall() {
    info "Verifying firewall..."

    if ! command -v ufw >/dev/null 2>&1; then
        register_result "Firewall" "INFO" "UFW is not installed"
        info "UFW not installed. Skipping firewall check."
        return
    fi

    if ! ufw status | grep -q "Status: active"; then
        register_result "Firewall" "WARN" "UFW is not active"
        warning "UFW is not active."
        return
    fi

    local missing=""

    if ! ufw status | grep -qE '22.*ALLOW'; then
        missing="${missing}SSH(22); "
    fi
    if ! ufw status | grep -qE '80.*ALLOW'; then
        missing="${missing}HTTP(80); "
    fi
    if ! ufw status | grep -qE '443.*ALLOW'; then
        missing="${missing}HTTPS(443); "
    fi

    if [[ -n "$missing" ]]; then
        register_result "Firewall" "WARN" "Missing rules: ${missing%%; }"
        warning "Missing firewall rules: ${missing%%; }"
    else
        register_result "Firewall" "PASS" "Active and all ports allowed"
        success "Firewall verified."
    fi
}

verify_url() {
    info "Verifying installer URL..."

    if ! command -v curl >/dev/null 2>&1; then
        register_result "InstallerURL" "INFO" "curl not installed"
        info "curl not available. Skipping URL check."
        return
    fi

    local status_code

    status_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 http://localhost/otobo/installer.pl 2>/dev/null || echo "000")
    status_code="${status_code:0:3}"

    case "$status_code" in
        200)
            register_result "InstallerURL" "PASS" "HTTP 200 at /otobo/installer.pl"
            success "Installer URL responding (HTTP 200)."
            ;;
        302)
            register_result "InstallerURL" "INFO" "HTTP 302 — installer already completed"
            info "Installer returns HTTP 302. OTOBO may already be configured."
            ;;
        000)
            register_result "InstallerURL" "FAIL" "Cannot reach Apache (connection refused)"
            warning "Cannot reach Apache on localhost:80."
            ;;
        *)
            register_result "InstallerURL" "WARN" "Unexpected HTTP ${status_code}"
            warning "Unexpected HTTP status: ${status_code}"
            ;;
    esac
}

# -------------------------------------------------
# Orchestrator
# -------------------------------------------------

run_verification() {
    line
    info "Running post-installation verification..."
    line

    verify_apache
    verify_mariadb
    verify_perl
    verify_otobo
    verify_database
    verify_permissions
    verify_firewall
    verify_url

    line
}

# -------------------------------------------------
# Main
# -------------------------------------------------

main() {
    show_banner

    run_verification

    validation_summary
    local result=$?

    echo
    if [[ "$result" -eq 0 ]]; then
        success "All critical checks passed."
    else
        warning "One or more critical checks failed. Review the report above."
    fi
    echo

    exit "$result"
}

main "$@"
