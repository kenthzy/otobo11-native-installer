#!/usr/bin/env bash

#############################################
# OTOBOSuite - OTOBO Management Suite
# System Validation Module
# Validates environment before installation
#############################################

# -------------------------------------------------
# Validation Results Registry
# Uses parallel arrays for Bash 3.x compatibility.
# Indexes in VALIDATION_NAMES, STATUSES, MESSAGES
# are kept in sync.
# -------------------------------------------------

VALIDATION_NAMES=()
VALIDATION_STATUSES=()
VALIDATION_MESSAGES=()

register_result() {
	local check_name="$1"
	local status="$2"
	local message="$3"

	VALIDATION_NAMES+=("$check_name")
	VALIDATION_STATUSES+=("$status")
	VALIDATION_MESSAGES+=("$message")
}

# -------------------------------------------------
# Individual Validation Checks
# -------------------------------------------------

check_root() {
	info "Checking root privileges..."

	if [[ $EUID -ne 0 ]]; then
		register_result "Root" "FAIL" "Not running as root — use sudo"
		error "This installer must be run with sudo."
	fi

	register_result "Root" "PASS" "Running with root privileges"
	success "Root privileges verified."
}

check_os() {
	info "Checking operating system..."

	if [[ ! -f /etc/os-release ]]; then
		register_result "OS" "FAIL" "Cannot determine OS — /etc/os-release missing"
		error "Unable to determine operating system."
	fi

	source /etc/os-release

	if ! os_is_supported; then
		register_result "OS" "FAIL" "Unsupported OS: $PRETTY_NAME"
		error "Unsupported operating system: $PRETTY_NAME"
	fi

	register_result "OS" "PASS" "$PRETTY_NAME"
	success "Operating System: $PRETTY_NAME"
}

check_internet() {
	info "Checking internet connection..."

	if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
		register_result "Internet" "PASS" "Connectivity verified (8.8.8.8)"
		success "Internet connection available."
	else
		register_result "Internet" "FAIL" "Cannot reach 8.8.8.8"
		error "No internet connection detected."
	fi
}

check_ram() {
	info "Checking system memory..."

	local total_ram_mb
	total_ram_mb=$(free -m | awk '/^Mem:/ {print $2}')

	if [[ "$total_ram_mb" -lt 1024 ]]; then
		register_result "RAM" "FAIL" "${total_ram_mb} MB — insufficient for installation"
		error "Insufficient memory (${total_ram_mb} MB). Minimum 1024 MB required."
	elif [[ "$total_ram_mb" -lt 2048 ]]; then
		register_result "RAM" "WARN" "${total_ram_mb} MB (2048 MB recommended)"
		warning "Low memory (${total_ram_mb} MB). 2048 MB recommended for production."
	else
		register_result "RAM" "PASS" "${total_ram_mb} MB"
		success "Memory: ${total_ram_mb} MB."
	fi
}

check_disk() {
	info "Checking available disk space..."

	local free_disk_gb
	free_disk_gb=$(df -BG / | awk 'NR==2 {gsub("G","",$4); print $4}')

	if [[ "$free_disk_gb" -lt 5 ]]; then
		register_result "Disk" "FAIL" "${free_disk_gb} GB free — cannot install"
		error "Insufficient disk space (${free_disk_gb} GB). Minimum 10 GB required."
	elif [[ "$free_disk_gb" -lt 10 ]]; then
		register_result "Disk" "FAIL" "${free_disk_gb} GB (10 GB minimum)"
		error "Insufficient disk space (${free_disk_gb} GB). Minimum 10 GB required."
	elif [[ "$free_disk_gb" -lt 20 ]]; then
		register_result "Disk" "WARN" "${free_disk_gb} GB (20 GB recommended)"
		warning "Low disk space (${free_disk_gb} GB). 20 GB recommended for production."
	else
		register_result "Disk" "PASS" "${free_disk_gb} GB"
		success "Available disk space: ${free_disk_gb} GB."
	fi
}

check_apache() {
	info "Checking web server..."

	if command -v nginx >/dev/null 2>&1; then
		if systemctl is-active --quiet nginx; then
			register_result "Nginx" "PASS" "Running ($(nginx -v 2>&1 | head -1))"
			success "nginx is installed and running."
		else
			register_result "Nginx" "WARN" "Installed but not running"
			warning "nginx is installed but not running."
		fi
	elif command -v apache2 >/dev/null 2>&1; then
		if systemctl is-active --quiet apache2; then
			register_result "Apache" "PASS" "Running ($(apache2 -v 2>/dev/null | head -1))"
			success "Apache is installed and running."
		else
			register_result "Apache" "WARN" "Installed but not running"
			warning "Apache is installed but not running."
		fi
	else
		register_result "Apache" "INFO" "Not installed (will be installed)"
		info "No web server installed. Will install during setup."
	fi
}

check_mariadb() {
	info "Checking database..."

	if command -v mariadb >/dev/null 2>&1 || command -v mysql >/dev/null 2>&1; then
		if systemctl is-active --quiet mariadb 2>/dev/null; then
			register_result "MariaDB" "PASS" "MariaDB installed and running"
			success "MariaDB is installed and running."
		else
			register_result "MariaDB" "INFO" "MariaDB installed (not running — will be configured)"
			info "MariaDB is installed but not running (will be configured later)."
		fi
	elif command -v psql >/dev/null 2>&1; then
		if systemctl is-active --quiet postgresql 2>/dev/null; then
			register_result "PostgreSQL" "PASS" "PostgreSQL installed and running"
			success "PostgreSQL is installed and running."
		else
			register_result "PostgreSQL" "INFO" "PostgreSQL installed (not running — will be configured)"
			info "PostgreSQL is installed but not running (will be configured later)."
		fi
	else
		register_result "Database" "INFO" "Not installed (will be installed)"
		info "No database engine installed. Will install during setup."
	fi
}

check_perl() {
	info "Checking Perl..."

	if ! command -v perl >/dev/null 2>&1; then
		register_result "Perl" "INFO" "Not installed (will be installed)"
		warning "Perl is not installed."
		return
	fi

	local perl_version
	perl_version=$(perl -e 'print $^V')

	register_result "Perl" "PASS" "Installed (${perl_version})"
	success "Perl installed (${perl_version})."
}

check_otobo() {
	info "Checking for existing OTOBO installation..."

	if [[ -d /opt/otobo ]]; then
		register_result "OTOBO" "WARN" "Existing installation detected at /opt/otobo"
		warning "Existing OTOBO installation detected at /opt/otobo."
	else
		register_result "OTOBO" "PASS" "No existing installation"
		success "No existing OTOBO installation detected."
	fi
}

# -------------------------------------------------
# Validation Orchestrator
# -------------------------------------------------

run_system_checks() {
	line
	info "Running system validation..."
	line

	check_root
	check_os
	check_internet
	check_ram
	check_disk
	check_apache
	check_mariadb
	check_perl
	check_otobo

	line
}

# -------------------------------------------------
# Validation Summary Report
# -------------------------------------------------

validation_summary() {
	local i
	local pass_count=0
	local warn_count=0
	local fail_count=0
	local info_count=0
	local skip_count=0
	local has_fail=0
	local check_name
	local status
	local message
	local formatted_status
	local col1_width=16
	local col2_width=10

	for i in "${!VALIDATION_NAMES[@]}"; do
		status="${VALIDATION_STATUSES[$i]}"
		case "$status" in
		PASS) ((pass_count++)) ;;
		WARN) ((warn_count++)) ;;
		FAIL)
			((fail_count++))
			has_fail=1
			;;
		INFO) ((info_count++)) ;;
		SKIP) ((skip_count++)) ;;
		esac
	done

	echo
	echo -e "${BOLD}============================================================${NC}"
	echo -e "${BOLD}$(printf '%*s' 22 "")SYSTEM VALIDATION REPORT${NC}"
	echo -e "${BOLD}============================================================${NC}"

	for i in "${!VALIDATION_NAMES[@]}"; do
		check_name="${VALIDATION_NAMES[$i]}"
		status="${VALIDATION_STATUSES[$i]}"
		message="${VALIDATION_MESSAGES[$i]}"

		case "$status" in
		PASS) formatted_status="${GREEN}PASS${NC}" ;;
		WARN) formatted_status="${YELLOW}WARN${NC}" ;;
		FAIL) formatted_status="${RED}FAIL${NC}" ;;
		INFO) formatted_status="${LIGHT_BLUE}INFO${NC}" ;;
		SKIP) formatted_status="${MAGENTA}SKIP${NC}" ;;
		esac

		printf " %-${col1_width}s  %-${col2_width}b  %s\n" "$check_name" "$formatted_status" "$message"
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

	if [[ "$has_fail" -eq 1 ]]; then
		return 1
	fi

	return 0
}
