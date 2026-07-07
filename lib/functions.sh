#!/usr/bin/env bash

#############################################
# OTOBO Native Installer
# Helper Functions
#############################################

line() {
    printf '%*s\n' "${COLUMNS:-60}" '' | tr ' ' '─'
}

info() {
    echo -e "${LIGHT_BLUE}[INFO]${NC} $1"
}

success() {
    echo -e "${GREEN}[ OK ]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[FAIL]${NC} $1"
    exit 1

}

check_root() {

    info "Checking sudo privileges..."

    if [[ $EUID -ne 0 ]]; then
        error "Please run this installer using sudo."
    fi

    success "Sudo privileges verified."
}

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
	
check_os() {

    info "Checking operating system..."

    if [[ ! -f /etc/os-release ]]; then
        error "Unable to determine operating system."
    fi

    source /etc/os-release

    if [[ "$ID" != "ubuntu" ]]; then
        error "Unsupported operating system: $PRETTY_NAME"
    fi

    success "Operating System: $PRETTY_NAME"

}

check_internet() {

    info "Checking internet connection..."

    if ping -c 1 -W 2 8.8.8.8 > /dev/null 2>&1; then
        success "Internet connection available."
    else
        error "No internet connection detected."
    fi

}

check_ram() {

    info "Checking system memory..."

    # Get total RAM in MB
    TOTAL_RAM_MB=$(free -m | awk '/^Mem:/ {print $2}')

    if [[ "$TOTAL_RAM_MB" -lt 2048 ]]; then
        warning "Low memory detected (${TOTAL_RAM_MB} MB). Minimum recommended is 2048 MB."
    else
        success "Memory detected: ${TOTAL_RAM_MB} MB."
    fi

}

check_disk() {

    info "Checking available disk space..."

    # Get available disk space in GB
    FREE_DISK_GB=$(df -BG / | awk 'NR==2 {gsub("G","",$4); print $4}')

    if [[ "$FREE_DISK_GB" -lt 10 ]]; then
        error "Insufficient disk space (${FREE_DISK_GB} GB). Minimum required is 10 GB."
    elif [[ "$FREE_DISK_GB" -lt 20 ]]; then
        warning "Low disk space (${FREE_DISK_GB} GB). Recommended is at least 20 GB."
    else
        success "Available disk space: ${FREE_DISK_GB} GB."
    fi

}	

check_apache() {

    info "Checking Apache..."

    if ! command -v apache2 >/dev/null 2>&1; then
        warning "Apache is not installed."
        return
    fi

    if systemctl is-active --quiet apache2; then
        success "Apache is installed and running."
    else
        warning "Apache is installed but not running."
    fi

}

check_mariadb() {

    info "Checking MariaDB..."

    if ! command -v mariadb >/dev/null 2>&1 && ! command -v mysql >/dev/null 2>&1; then
        warning "MariaDB is not installed."
        return
    fi

    if systemctl is-active --quiet mariadb; then
        success "MariaDB is installed and running."
    else
        warning "MariaDB is installed but not running."
    fi

}

check_perl() {

    info "Checking Perl..."

    if ! command -v perl >/dev/null 2>&1; then
        warning "Perl is not installed."
        return
    fi

    PERL_VERSION=$(perl -e 'print $^V')

    success "Perl installed (${PERL_VERSION})."

}

check_otobo() {

    info "Checking existing OTOBO installation..."

    if [[ -d /opt/otobo ]]; then
        warning "Existing OTOBO installation detected at /opt/otobo."
    else
        success "No existing OTOBO installation detected."
    fi

}
