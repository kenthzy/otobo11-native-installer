#!/usr/bin/env bash

#############################################
# OTOBOSuite - OTOBO Management Suite
# Apache Installation Module
#############################################

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
