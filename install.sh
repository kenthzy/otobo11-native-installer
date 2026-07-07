#!/usr/bin/env bash

#####################################################
# OTOBO Native Installer
# Automated by System Admin Kenneth
#####################################################

set -e

source lib/colors.sh
source lib/banner.sh
source lib/functions.sh

show_banner

run_system_checks

success "Framework loaded successfully."

echo
echo "Ready to continue."
echo
