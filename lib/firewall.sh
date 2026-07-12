#!/usr/bin/env bash

#############################################
# OTOBOSuite - OTOBO Management Suite
# Firewall Configuration Module
#############################################

configure_firewall() {
    info "Configuring firewall..."

    if ! command -v ufw >/dev/null 2>&1; then
        info "Installing UFW..."
        apt-get install -y ufw
        success "UFW installed."
    fi

    ufw allow OpenSSH
    ufw allow 80/tcp
    ufw allow 443/tcp

    success "Firewall rules configured (SSH, HTTP, HTTPS)."

    if ufw status | grep -q "Status: active"; then
        register_result "Firewall" "PASS" "UFW active — SSH, HTTP, HTTPS allowed"
        success "UFW is active."
    else
        register_result "Firewall" "WARN" "Rules configured but UFW not enabled"
        warning "UFW is currently disabled."
        warning "Firewall rules have been configured but not enabled."
        warning "Enable manually when appropriate: sudo ufw enable"
    fi
}
