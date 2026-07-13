#!/usr/bin/env bash

#############################################
# OTOBOSuite - OTOBO Management Suite
# Automatic Repair Module
# Run: sudo ./repair.sh
#      sudo ./repair.sh --check
#############################################

set -e

source lib/colors.sh
source lib/banner.sh
source lib/functions.sh
source lib/validation.sh

# -------------------------------------------------
# Constants
# -------------------------------------------------

CREDS_FILE="/root/.otobo_db_credentials"
CONFIG_FILE="/opt/otobo/Kernel/Config.pm"
APACHE_SITE="zzz_otobo"
REQUIRED_APACHE_MODS="perl deflate headers rewrite proxy proxy_http ssl"

# -------------------------------------------------
# Repair Results Registry
# -------------------------------------------------

REPAIR_NAMES=()
REPAIR_DIAG_STATUSES=()
REPAIR_DIAG_MESSAGES=()
REPAIR_REPAIR_STATUSES=()
REPAIR_REPAIR_MESSAGES=()

register_diagnosis() {
	local name="$1"
	local status="$2"
	local message="$3"

	REPAIR_NAMES+=("$name")
	REPAIR_DIAG_STATUSES+=("$status")
	REPAIR_DIAG_MESSAGES+=("$message")
	REPAIR_REPAIR_STATUSES+=("")
	REPAIR_REPAIR_MESSAGES+=("")
}

register_repair() {
	local index="$1"
	local status="$2"
	local message="$3"

	REPAIR_REPAIR_STATUSES[index]="$status"
	REPAIR_REPAIR_MESSAGES[index]="$message"
}

# -------------------------------------------------
# Diagnostic Functions
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

diagnose_apache() {
	local ws
	ws=$(detect_webserver)

	if [[ "$ws" == "nginx" ]]; then
		diagnose_nginx
		return
	fi

	info "Checking Apache..."

	if ! command -v apache2 >/dev/null 2>&1; then
		register_diagnosis "Apache" "FAIL" "Apache is not installed"
		warning "Apache is not installed."
		return
	fi

	if ! systemctl is-active --quiet apache2 2>/dev/null; then
		register_diagnosis "Apache" "FAIL" "Apache is not running"
		warning "Apache is not running."
		return
	fi

	local issues=""

	if ! a2query -s "$APACHE_SITE" 2>/dev/null | grep -q "enabled"; then
		issues="${issues}OTBO vhost not enabled; "
	fi

	local mod
	for mod in $REQUIRED_APACHE_MODS; do
		if ! a2query -m "$mod" 2>/dev/null | grep -q "enabled"; then
			issues="${issues}mod_${mod} not enabled; "
		fi
	done

	if ! apache2ctl configtest 2>/dev/null; then
		issues="${issues}config syntax error; "
	fi

	if [[ -n "$issues" ]]; then
		register_diagnosis "Apache" "WARN" "${issues%%; }"
		warning "Apache issues found: ${issues%%; }"
	else
		register_diagnosis "Apache" "PASS" "Running, OTOBO site enabled, all modules loaded"
		success "Apache is healthy."
	fi
}

diagnose_nginx() {
	info "Checking nginx..."

	if ! command -v nginx >/dev/null 2>&1; then
		register_diagnosis "Nginx" "FAIL" "nginx is not installed"
		warning "nginx is not installed."
		return
	fi

	if ! systemctl is-active --quiet nginx 2>/dev/null; then
		register_diagnosis "Nginx" "FAIL" "nginx is not running"
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
			register_diagnosis "Starman" "PASS" "Starman is running"
		else
			issues="${issues}Starman not running; "
		fi
	fi

	if [[ -n "$issues" ]]; then
		register_diagnosis "Nginx" "WARN" "${issues%%; }"
		warning "nginx issues found: ${issues%%; }"
	else
		register_diagnosis "Nginx" "PASS" "Running, OTOBO site configured, config valid"
		success "nginx is healthy."
	fi
}

detect_db_engine() {
	if [[ -f "$CREDS_FILE" ]]; then
		# shellcheck disable=SC1090
		source "$CREDS_FILE"
		echo "${DB_ENGINE:-mariadb}"
	else
		echo "mariadb"
	fi
}

diagnose_mariadb() {
	local engine
	engine=$(detect_db_engine)

	if [[ "$engine" == "postgresql" ]]; then
		diagnose_postgresql
		return
	fi

	info "Checking MariaDB..."

	if ! command -v mariadb >/dev/null 2>&1 && ! command -v mysql >/dev/null 2>&1; then
		register_diagnosis "MariaDB" "FAIL" "MariaDB is not installed"
		warning "MariaDB is not installed."
		return
	fi

	if ! systemctl is-active --quiet mariadb 2>/dev/null; then
		register_diagnosis "MariaDB" "FAIL" "MariaDB is not running"
		warning "MariaDB is not running."
		return
	fi

	if ! mysql -e "USE otobo" 2>/dev/null; then
		register_diagnosis "MariaDB" "WARN" "OTBO database 'otobo' does not exist"
		warning "OTBO database 'otobo' does not exist."
	else
		register_diagnosis "MariaDB" "PASS" "Running and OTOBO database exists"
		success "MariaDB is healthy."
	fi
}

diagnose_postgresql() {
	info "Checking PostgreSQL..."

	if ! command -v psql >/dev/null 2>&1; then
		register_diagnosis "PostgreSQL" "FAIL" "PostgreSQL is not installed"
		warning "PostgreSQL is not installed."
		return
	fi

	if ! systemctl is-active --quiet postgresql 2>/dev/null; then
		register_diagnosis "PostgreSQL" "FAIL" "PostgreSQL is not running"
		warning "PostgreSQL is not running."
		return
	fi

	if su - postgres -c "psql -lqt 2>/dev/null" | cut -d \| -f 1 | grep -qw "otobo"; then
		register_diagnosis "PostgreSQL" "PASS" "Running and OTOBO database exists"
		success "PostgreSQL is healthy."
	else
		register_diagnosis "PostgreSQL" "WARN" "OTBO database 'otobo' does not exist"
		warning "OTBO database 'otobo' does not exist."
	fi
}

diagnose_perl() {
	local check_modules_script="/opt/otobo/bin/otobo.CheckModules.pl"

	info "Checking Perl modules..."

	if ! command -v perl >/dev/null 2>&1; then
		register_diagnosis "PerlModules" "FAIL" "Perl is not installed"
		warning "Perl is not installed."
		return
	fi

	if [[ ! -x "$check_modules_script" ]]; then
		register_diagnosis "PerlModules" "INFO" "OTBO not installed — cannot run module check"
		info "OTBO not installed. Skipping Perl module check."
		return
	fi

	if "$check_modules_script" --list >/dev/null 2>&1; then
		register_diagnosis "PerlModules" "PASS" "All required Perl modules are installed"
		success "All required Perl modules present."
	else
		register_diagnosis "PerlModules" "WARN" "Some Perl modules are missing"
		warning "Some Perl modules are missing."
	fi
}

diagnose_permissions() {
	info "Checking file permissions..."

	if [[ ! -d /opt/otobo ]]; then
		register_diagnosis "Permissions" "INFO" "OTBO not installed — skipping permissions check"
		info "OTBO not installed. Skipping permissions check."
		return
	fi

	local owner
	owner=$(stat -c '%U:%G' /opt/otobo 2>/dev/null || stat -f '%Su:%Sg' /opt/otobo 2>/dev/null)

	if [[ "$owner" != "otobo:www-data" ]]; then
		register_diagnosis "Permissions" "WARN" "Ownership is ${owner} (expected otobo:www-data)"
		warning "Ownership is ${owner}, expected otobo:www-data."
	else
		register_diagnosis "Permissions" "PASS" "Ownership is otobo:www-data"
		success "File permissions are correct."
	fi
}

diagnose_config() {
	info "Checking Kernel/Config.pm..."

	if [[ ! -f "$CONFIG_FILE" ]]; then
		register_diagnosis "Config" "WARN" "Kernel/Config.pm does not exist"
		warning "Kernel/Config.pm not found."
		return
	fi

	if ! perl -c "$CONFIG_FILE" >/dev/null 2>&1; then
		register_diagnosis "Config" "FAIL" "Kernel/Config.pm has syntax errors"
		warning "Kernel/Config.pm has syntax errors."
		return
	fi

	local db_name
	local db_user
	local db_pw

	db_name=$(perl -ne 'print $1 if /\$Self->\{Database\}\s*=\s*'\''([^'\'']+)/' "$CONFIG_FILE")
	db_user=$(perl -ne 'print $1 if /\$Self->\{DatabaseUser\}\s*=\s*'\''([^'\'']+)/' "$CONFIG_FILE")
	db_pw=$(perl -ne 'print $1 if /\$Self->\{DatabasePw\}\s*=\s*'\''([^'\'']+)/' "$CONFIG_FILE")

	if [[ -z "$db_name" || -z "$db_user" || -z "$db_pw" || "$db_pw" == "some-pass" ]]; then
		register_diagnosis "Config" "WARN" "Database settings in Config.pm are incomplete or default"
		warning "Database settings in Config.pm are incomplete or use defaults."
	else
		register_diagnosis "Config" "PASS" "Config.pm exists, syntax valid, DB settings populated"
		success "Kernel/Config.pm is valid."
	fi
}

diagnose_db_connection() {
	info "Testing database connection..."

	if [[ ! -f "$CONFIG_FILE" ]]; then
		register_diagnosis "DBConnection" "SKIP" "Config.pm not found — cannot test"
		info "Config.pm not found. Skipping database connection test."
		return
	fi

	local db_user
	local db_pw
	local db_host

	db_host=$(perl -ne 'print $1 if /\$Self->\{DatabaseHost\}\s*=\s*'\''([^'\'']+)/' "$CONFIG_FILE")
	db_user=$(perl -ne 'print $1 if /\$Self->\{DatabaseUser\}\s*=\s*'\''([^'\'']+)/' "$CONFIG_FILE")
	db_pw=$(perl -ne 'print $1 if /\$Self->\{DatabasePw\}\s*=\s*'\''([^'\'']+)/' "$CONFIG_FILE")

	db_host="${db_host:-localhost}"
	db_user="${db_user:-otobo}"

	if [[ -z "$db_pw" || "$db_pw" == "some-pass" ]]; then
		register_diagnosis "DBConnection" "FAIL" "Database password is not set or still default"
		warning "Cannot test database connection — password is default or empty."
		return
	fi

	if mysql -u "$db_user" -p"$db_pw" -h "$db_host" -e "SELECT 1" >/dev/null 2>&1; then
		register_diagnosis "DBConnection" "PASS" "Successfully connected to database"
		success "Database connection verified."
	else
		register_diagnosis "DBConnection" "FAIL" "Cannot connect to database with Config.pm credentials"
		warning "Cannot connect to database with Config.pm credentials."
	fi
}

diagnose_firewall() {
	info "Checking firewall..."

	if ! command -v ufw >/dev/null 2>&1; then
		register_diagnosis "Firewall" "INFO" "UFW is not installed"
		info "UFW not installed. Skipping firewall check."
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
		register_diagnosis "Firewall" "WARN" "Missing rules: ${missing%%; }"
		warning "Missing firewall rules: ${missing%%; }"
	else
		register_diagnosis "Firewall" "PASS" "All required ports allowed"
		success "Firewall rules are correct."
	fi
}

diagnose_forbidden() {
	info "Checking for 403 Forbidden errors..."

	local log_file="/var/log/apache2/error.log"

	if [[ ! -f "$log_file" ]]; then
		register_diagnosis "Forbidden" "SKIP" "Apache error log not found"
		info "Apache error log not found. Skipping 403 check."
		return
	fi

	if grep -q "403" "$log_file" 2>/dev/null; then
		register_diagnosis "Forbidden" "WARN" "403 errors found in Apache error log"
		warning "403 errors detected in Apache logs."
	else
		register_diagnosis "Forbidden" "PASS" "No 403 errors in Apache error log"
		success "No 403 errors detected."
	fi
}

# -------------------------------------------------
# Repair Functions
# -------------------------------------------------

repair_apache() {
	local idx="$1"
	local ws
	ws=$(detect_webserver)

	if [[ "$ws" == "nginx" ]]; then
		repair_nginx "$idx"
		return
	fi

	info "Repairing Apache..."

	if ! systemctl is-active --quiet apache2 2>/dev/null; then
		systemctl start apache2 || true
	fi

	if ! a2query -s "$APACHE_SITE" 2>/dev/null | grep -q "enabled"; then
		a2ensite "$APACHE_SITE" >/dev/null 2>&1 || true
	fi

	local mod
	for mod in $REQUIRED_APACHE_MODS; do
		if ! a2query -m "$mod" 2>/dev/null | grep -q "enabled"; then
			a2enmod "$mod" >/dev/null 2>&1 || true
		fi
	done

	apache2ctl configtest >/dev/null 2>&1 || true
	systemctl restart apache2 || true

	register_repair "$idx" "FIXED" "Apache started, site enabled, modules loaded, restarted"
	success "Apache repaired."
}

repair_nginx() {
	local idx="$1"
	info "Repairing nginx..."

	if ! systemctl is-active --quiet nginx 2>/dev/null; then
		systemctl start nginx || true
	fi

	if [[ ! -f /etc/nginx/sites-available/otobo ]]; then
		cp /opt/otobo/scripts/apache2-httpd.include.conf /etc/nginx/sites-available/otobo 2>/dev/null || true
	fi

	if [[ -L /etc/nginx/sites-enabled/default ]]; then
		rm -f /etc/nginx/sites-enabled/default
	fi

	if [[ ! -L /etc/nginx/sites-enabled/otobo ]]; then
		ln -sf /etc/nginx/sites-available/otobo /etc/nginx/sites-enabled/
	fi

	nginx -t >/dev/null 2>&1 || true
	systemctl restart nginx || true

	if command -v starman >/dev/null 2>&1; then
		if ! systemctl is-active --quiet otobo-starman 2>/dev/null; then
			systemctl start otobo-starman || true
		fi
	fi

	register_repair "$idx" "FIXED" "nginx started, site enabled, config reloaded"
	success "nginx repaired."
}

repair_mariadb() {
	local idx="$1"
	local engine
	engine=$(detect_db_engine)

	if [[ "$engine" == "postgresql" ]]; then
		repair_postgresql "$idx"
		return
	fi

	info "Repairing MariaDB..."

	if ! systemctl is-active --quiet mariadb 2>/dev/null; then
		systemctl start mariadb || true
	fi

	if [[ -f "$CREDS_FILE" ]]; then
		# shellcheck disable=SC1090
		source "$CREDS_FILE"
		mysql <<-EOF
			CREATE DATABASE IF NOT EXISTS ${OTOBO_DB_NAME}
			    CHARACTER SET utf8mb4
			    COLLATE utf8mb4_unicode_ci;

			CREATE USER IF NOT EXISTS '${OTOBO_DB_USER}'@'${OTOBO_DB_HOST}'
			    IDENTIFIED BY '${OTOBO_DB_PASSWORD}';

			GRANT ALL PRIVILEGES ON ${OTOBO_DB_NAME}.*
			    TO '${OTOBO_DB_USER}'@'${OTOBO_DB_HOST}';

			FLUSH PRIVILEGES;
		EOF
		register_repair "$idx" "FIXED" "Database and user recreated"
	else
		mysql -e "CREATE DATABASE IF NOT EXISTS otobo CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
		register_repair "$idx" "FIXED" "Database created (no credentials file)"
	fi

	success "MariaDB repaired."
}

repair_postgresql() {
	local idx="$1"
	info "Repairing PostgreSQL..."

	if ! systemctl is-active --quiet postgresql 2>/dev/null; then
		systemctl start postgresql || true
	fi

	if [[ -f "$CREDS_FILE" ]]; then
		# shellcheck disable=SC1090
		source "$CREDS_FILE"
		local user_exists
		user_exists=$(su - postgres -c "psql -t -c \"SELECT 1 FROM pg_roles WHERE rolname='${OTOBO_DB_USER}'\"" 2>/dev/null | tr -d ' ')
		if [[ "$user_exists" != "1" ]]; then
			su - postgres -c "psql -c \"CREATE USER ${OTOBO_DB_USER} WITH PASSWORD '${OTOBO_DB_PASSWORD}'\"" 2>/dev/null || true
		fi
		su - postgres -c "psql -c \"CREATE DATABASE ${OTOBO_DB_NAME} OWNER ${OTOBO_DB_USER} ENCODING 'UTF8'\"" 2>/dev/null || true
		su - postgres -c "psql -c \"GRANT ALL PRIVILEGES ON DATABASE ${OTOBO_DB_NAME} TO ${OTOBO_DB_USER}\"" 2>/dev/null || true
		register_repair "$idx" "FIXED" "Database and user recreated"
	fi

	success "PostgreSQL repaired."
}

repair_perl_modules() {
	local idx="$1"
	info "Repairing Perl modules..."

	source lib/perl.sh
	install_perl

	register_repair "$idx" "FIXED" "Perl modules reinstalled"
	success "Perl modules repaired."
}

repair_permissions() {
	local idx="$1"
	info "Repairing file permissions..."

	if [[ ! -d /opt/otobo ]]; then
		register_repair "$idx" "SKIP" "OTBO not installed"
		info "OTBO not installed. Skipping permissions repair."
		return
	fi

	chown -R otobo:www-data /opt/otobo
	find /opt/otobo -type d -exec chmod 755 {} \;
	find /opt/otobo -type f -exec chmod 644 {} \;
	chmod 755 /opt/otobo/bin/* >/dev/null 2>&1 || true

	register_repair "$idx" "FIXED" "Ownership and permissions corrected"
	success "File permissions repaired."
}

repair_config() {
	local idx="$1"
	info "Repairing Kernel/Config.pm..."

	source lib/otobo.sh
	write_config

	register_repair "$idx" "FIXED" "Kernel/Config.pm rewritten from credentials"
	success "Config.pm repaired."
}

repair_db_connection() {
	local idx="$1"
	local engine
	engine=$(detect_db_engine)

	info "Repairing database connection..."

	if [[ ! -f "$CREDS_FILE" ]]; then
		register_repair "$idx" "FAIL" "Credentials file not found"
		warning "Cannot repair database connection — credentials file missing."
		return
	fi

	# shellcheck disable=SC1090
	source "$CREDS_FILE"

	if [[ "$engine" == "postgresql" ]]; then
		repair_db_connection_pg "$idx"
		return
	fi

	mysql <<-EOF
		GRANT ALL PRIVILEGES ON ${OTOBO_DB_NAME}.*
		    TO '${OTOBO_DB_USER}'@'${OTOBO_DB_HOST}';
		FLUSH PRIVILEGES;
	EOF

	if mysql -u "${OTOBO_DB_USER}" -p"${OTOBO_DB_PASSWORD}" -h "${OTOBO_DB_HOST}" -e "SELECT 1" >/dev/null 2>&1; then
		register_repair "$idx" "FIXED" "Database privileges re-granted, connection verified"
		success "Database connection repaired."
	else
		register_repair "$idx" "FAIL" "Still unable to connect after re-grant"
		warning "Database connection still failing after repair."
	fi
}

repair_db_connection_pg() {
	local idx="$1"

	su - postgres -c "psql -c \"GRANT ALL PRIVILEGES ON DATABASE ${OTOBO_DB_NAME} TO ${OTOBO_DB_USER}\"" 2>/dev/null || true

	if PGPASSWORD="${OTOBO_DB_PASSWORD}" psql -h "${OTOBO_DB_HOST}" -U "${OTOBO_DB_USER}" -d "${OTOBO_DB_NAME}" -c "SELECT 1" >/dev/null 2>&1; then
		register_repair "$idx" "FIXED" "Database privileges re-granted, connection verified"
		success "Database connection repaired."
	else
		register_repair "$idx" "FAIL" "Still unable to connect after re-grant"
		warning "Database connection still failing after repair."
	fi
}

repair_firewall() {
	local idx="$1"
	info "Repairing firewall..."

	if ! command -v ufw >/dev/null 2>&1; then
		apt-get install -y ufw
	fi

	ufw allow OpenSSH >/dev/null 2>&1 || true
	ufw allow 80/tcp >/dev/null 2>&1 || true
	ufw allow 443/tcp >/dev/null 2>&1 || true

	register_repair "$idx" "FIXED" "Firewall rules added for SSH, HTTP, HTTPS"
	success "Firewall repaired."
}

repair_forbidden() {
	local idx="$1"
	info "Repairing 403 Forbidden issues..."

	if [[ -d /opt/otobo ]]; then
		chmod 755 /opt/otobo/var/httpd/htdocs >/dev/null 2>&1 || true
		chown -R otobo:www-data /opt/otobo/var/httpd/htdocs >/dev/null 2>&1 || true
	fi

	if ! a2query -s "$APACHE_SITE" 2>/dev/null | grep -q "enabled"; then
		a2ensite "$APACHE_SITE" >/dev/null 2>&1 || true
	fi

	systemctl restart apache2 || true

	register_repair "$idx" "FIXED" "Permissions corrected and Apache restarted"
	success "403 Forbidden repair completed."
}

# -------------------------------------------------
# Orchestrators
# -------------------------------------------------

run_diagnostics() {
	line
	info "Running diagnostics..."
	line

	diagnose_apache
	diagnose_mariadb
	diagnose_perl
	diagnose_permissions
	diagnose_config
	diagnose_db_connection
	diagnose_firewall
	diagnose_forbidden

	line
}

repair_all() {
	line
	info "Repairing all issues..."
	line

	local i
	for i in "${!REPAIR_NAMES[@]}"; do
		local status="${REPAIR_DIAG_STATUSES[$i]}"
		if [[ "$status" == "FAIL" || "$status" == "WARN" ]]; then
			local name="${REPAIR_NAMES[$i]}"
			case "$name" in
			Apache) repair_apache "$i" ;;
			MariaDB) repair_mariadb "$i" ;;
			PerlModules) repair_perl_modules "$i" ;;
			Permissions) repair_permissions "$i" ;;
			Config) repair_config "$i" ;;
			DBConnection) repair_db_connection "$i" ;;
			Firewall) repair_firewall "$i" ;;
			Forbidden) repair_forbidden "$i" ;;
			*)
				register_repair "$i" "SKIP" "No repair handler for ${name}"
				warning "No repair handler for ${name}."
				;;
			esac
		else
			register_repair "$i" "SKIP" "No repair needed"
		fi
	done

	line
}

show_repair_summary() {
	local pass_count=0
	local fixed_count=0
	local fail_count=0
	local skip_count=0
	local warn_count=0
	local i

	for i in "${!REPAIR_NAMES[@]}"; do
		local diag="${REPAIR_DIAG_STATUSES[$i]}"
		local repair="${REPAIR_REPAIR_STATUSES[$i]}"

		if [[ -n "$repair" ]]; then
			case "$repair" in
			FIXED) ((fixed_count++)) ;;
			FAIL) ((fail_count++)) ;;
			SKIP) ((skip_count++)) ;;
			esac
		else
			case "$diag" in
			PASS | INFO) ((pass_count++)) ;;
			WARN) ((warn_count++)) ;;
			FAIL) ((fail_count++)) ;;
			SKIP) ((skip_count++)) ;;
			esac
		fi
	done

	echo
	echo -e "${BOLD}============================================================${NC}"
	echo -e "${BOLD}$(printf '%*s' 28 "")REPAIR SUMMARY${NC}"
	echo -e "${BOLD}============================================================${NC}"

	for i in "${!REPAIR_NAMES[@]}"; do
		local name="${REPAIR_NAMES[$i]}"
		local diag="${REPAIR_DIAG_STATUSES[$i]}"
		local repair="${REPAIR_REPAIR_STATUSES[$i]}"
		local message=""
		local formatted_status=""

		if [[ -n "$repair" ]]; then
			message="${REPAIR_REPAIR_MESSAGES[$i]}"
			case "$repair" in
			FIXED) formatted_status="${GREEN}FIXED${NC}" ;;
			FAIL) formatted_status="${RED}FAIL${NC}" ;;
			SKIP) formatted_status="${MAGENTA}SKIP${NC}" ;;
			*) formatted_status="${diag}" ;;
			esac
		else
			message="${REPAIR_DIAG_MESSAGES[$i]}"
			case "$diag" in
			PASS) formatted_status="${GREEN}PASS${NC}" ;;
			WARN) formatted_status="${YELLOW}WARN${NC}" ;;
			FAIL) formatted_status="${RED}FAIL${NC}" ;;
			INFO) formatted_status="${LIGHT_BLUE}INFO${NC}" ;;
			SKIP) formatted_status="${MAGENTA}SKIP${NC}" ;;
			esac
		fi

		printf " %-16s  %-8b  %s\n" "$name" "$formatted_status" "$message"
	done

	echo -e "${BOLD}============================================================${NC}"
	local total=$((pass_count + fixed_count + fail_count + skip_count + warn_count))
	local result_line="Result: ${GREEN}${pass_count} PASS${NC}"
	result_line+=", ${YELLOW}${warn_count} WARN${NC}"
	result_line+=", ${GREEN}${fixed_count} FIXED${NC}"
	result_line+=", ${RED}${fail_count} FAIL${NC}, ${MAGENTA}${skip_count} SKIP${NC}"
	result_line+=" (${total} total)"

	echo -e " ${result_line}"
	echo -e "${BOLD}============================================================${NC}"
	echo
}

# -------------------------------------------------
# Main
# -------------------------------------------------

main() {
	show_banner

	if [[ "$1" == "--check" ]]; then
		run_diagnostics
		show_repair_summary
		exit 0
	fi

	run_diagnostics

	local issue_count=0
	local i
	for i in "${!REPAIR_DIAG_STATUSES[@]}"; do
		if [[ "${REPAIR_DIAG_STATUSES[$i]}" == "FAIL" || "${REPAIR_DIAG_STATUSES[$i]}" == "WARN" ]]; then
			((issue_count++))
		fi
	done

	if [[ "$issue_count" -eq 0 ]]; then
		echo
		success "All checks passed. No repairs needed."
		echo
		exit 0
	fi

	echo
	warning "${issue_count} issue(s) detected."
	echo

	if confirm "Repair all detected issues?" "Y"; then
		repair_all
		show_repair_summary
		success "Repair process completed."
	else
		info "No repairs were applied."
	fi

	echo
}

main "$@"
