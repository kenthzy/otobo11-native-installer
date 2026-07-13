#!/usr/bin/env bash

#############################################
# OTOBOSuite - OTOBO Management Suite
# Apache Installation Module
#############################################

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

prompt_web_server() {
    source "$SCRIPT_DIR/lib/config.sh"
    load_config

    local cfg_ws
    cfg_ws=$(config_value "WEB_SERVER" "")

    if [[ -n "$cfg_ws" ]]; then
        WEB_SERVER="$cfg_ws"
        info "Using web server from config file: $WEB_SERVER"
        return
    fi

    echo
    echo -e "${BOLD}Web Server Selection${NC}"
    echo -e "${BOLD}-------------------${NC}"
    echo
    echo " Choose your web server:"
    echo "   1) Apache (default)     — mod_perl, mpm_prefork"
    echo "   2) nginx + Starman      — Reverse proxy + PSGI"
    echo
    read -rp " Enter your choice [1/2] (default: 1): " ws_choice

    if [[ "$ws_choice" == "2" ]]; then
        WEB_SERVER="nginx"
    else
        WEB_SERVER="apache"
    fi
}

install_apache() {
    info "Installing Apache and mod_perl..."

    apt-get install -y apache2 libapache2-mod-perl2

    success "Apache and mod_perl installed."

    info "Enabling required Apache modules..."

    a2enmod perl
    a2enmod deflate
    a2enmod headers
    a2enmod rewrite
    a2enmod proxy
    a2enmod proxy_http
    a2enmod ssl

    success "Required Apache modules enabled."

    info "Switching to mpm_prefork for mod_perl compatibility..."

    a2dismod mpm_event
    a2enmod mpm_prefork

    success "Apache MPM set to prefork."

    info "Starting and enabling Apache..."

    systemctl enable apache2
    systemctl restart apache2

    success "Apache started and enabled."

    register_result "ApacheInstall" "PASS" "Apache 2.4 with mod_perl, mpm_prefork"
}
