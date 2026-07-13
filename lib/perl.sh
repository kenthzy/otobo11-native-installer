#!/usr/bin/env bash

install_perl_deps() {
	local db_engine="$1"
	info "Installing Perl dependencies..."
	pkg_install perl libcrypt-eksblowfish-perl libjson-perl libxml-libxml-perl libyaml-libyaml-perl libnet-dns-perl libmail-imapclient-perl libauthen-sasl-perl libdatetime-perl libwww-perl

	if [ "$db_engine" = "postgresql" ]; then
		pkg_install libdbd-pg-perl
	else
		pkg_install libdbd-mysql-perl
	fi
	register_result "Perl Deps" "OK" "Perl dependencies installed for $db_engine"
}
