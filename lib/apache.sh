#!/usr/bin/env bash

install_apache() {
	info "Installing Apache with mod_perl..."
	pkg_install apache2 libapache2-mod-perl2
	a2enmod perl
	a2enmod rewrite
	a2enmod headers
	a2enmod ssl
	register_result "Apache Install" "OK" "Apache with mod_perl installed"
}

configure_apache_site() {
	local fqdn="$1"
	local otobo_root="$2"
	local ssl_mode="${3:-none}"

	cat >/etc/apache2/sites-available/otobo.conf <<APACHE
<VirtualHost *:80>
    ServerName ${fqdn}
    DocumentRoot ${otobo_root}

    <Directory ${otobo_root}>
        AllowOverride All
        Require all granted
    </Directory>

    <Location /otobo>
        SetHandler perl-script
        PerlResponseHandler ModPerl::Registry
        PerlOptions +ParseHeaders
        Options +ExecCGI
    </Location>

    ErrorLog \${APACHE_LOG_DIR}/otobo_error.log
    CustomLog \${APACHE_LOG_DIR}/otobo_access.log combined
</VirtualHost>
APACHE

	if [ "$ssl_mode" = "self-signed" ] || [ "$ssl_mode" = "letsencrypt" ]; then
		cat >/etc/apache2/sites-available/otobo-ssl.conf <<APACHESSL
<VirtualHost *:443>
    ServerName ${fqdn}
    DocumentRoot ${otobo_root}

    SSLEngine on
    SSLCertificateFile /etc/ssl/certs/otobo.crt
    SSLCertificateKeyFile /etc/ssl/private/otobo.key

    <Directory ${otobo_root}>
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/otobo_ssl_error.log
    CustomLog \${APACHE_LOG_DIR}/otobo_ssl_access.log combined
</VirtualHost>
APACHESSL
		a2ensite otobo-ssl
	fi

	a2dissite 000-default
	a2ensite otobo
	systemctl reload apache2
	register_result "Apache Site" "OK" "Site configured for $fqdn"
}
