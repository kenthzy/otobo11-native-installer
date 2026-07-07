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
