#!/usr/bin/env bash

#####################################################
# OTOBOSuite - OTOBO Management Suite
# Ubuntu 24.04 LTS — Apache — MariaDB
#####################################################

set -e

source lib/colors.sh
source lib/banner.sh
source lib/functions.sh
source lib/config.sh
source lib/validation.sh

load_config

show_banner
pause

run_system_checks

if ! validation_summary; then
    echo
    warning "One or more validation checks failed."
    echo "Review the report above before proceeding."
    echo

    if confirm "Continue with installation anyway?" "N"; then
        echo
        info "Proceeding with installation..."
    else
        error "Installation aborted by user."
    fi
fi

line
info "Phase 3: Package Installation"
line

info "Updating package lists..."
apt-get update

source lib/apache.sh
install_apache

source lib/mariadb.sh
prompt_db_engine
echo

if [[ "$DB_ENGINE" == "postgresql" ]]; then
    source lib/postgresql.sh
    install_postgresql
else
    install_mariadb
fi

source lib/perl.sh
install_perl

source lib/firewall.sh
configure_firewall

echo
success "Package installation complete."

source lib/otobo.sh
install_otobo
