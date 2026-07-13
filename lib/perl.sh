#!/usr/bin/env bash

#############################################
# OTOBOSuite - OTOBO Management Suite
# Perl Installation Module
#############################################

install_perl() {
    info "Installing Perl dependencies..."

    local db_driver="libdbd-mysql-perl"
    if [[ "${DB_ENGINE:-mariadb}" == "postgresql" ]]; then
        db_driver="libdbd-pg-perl"
    fi

    apt-get install -y \
        build-essential \
        cpanminus \
        libarchive-zip-perl \
        libauthen-ntlm-perl \
        libauthen-sasl-perl \
        libcgi-psgi-perl \
        libconst-fast-perl \
        libconvert-binhex-perl \
        libcrypt-eksblowfish-perl \
        libdatetime-perl \
        "$db_driver" \
        libdbi-perl \
        libdbix-connector-perl \
        libencode-hanextra-perl \
        libfile-chmod-perl \
        libio-socket-ssl-perl \
        libjson-xs-perl \
        liblist-allutils-perl \
        liblwp-useragent-determined-perl \
        libmail-imapclient-perl \
        libmoo-perl \
        libnamespace-autoclean-perl \
        libnet-dns-perl \
        libnet-ldap-perl \
        libnet-smtp-ssl-perl \
        libpath-class-perl \
        libplack-middleware-header-perl \
        libplack-middleware-reverseproxy-perl \
        libplack-perl \
        libsub-exporter-perl \
        libtemplate-perl \
        libtext-csv-xs-perl \
        libtext-trim-perl \
        libtimedate-perl \
        libtry-tiny-perl \
        liburi-perl \
        libxml-libxml-perl \
        libxml-libxslt-perl \
        libxml-parser-perl \
        libyaml-libyaml-perl

    success "Perl dependencies installed."

    register_result "PerlInstall" "PASS" "Perl 5 + all OTOBO modules installed via apt"
}
