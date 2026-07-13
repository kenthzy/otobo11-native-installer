#!/usr/bin/env bash

configure_unattended_upgrades() {
	info "Configuring automatic security updates..."
	pkg_install unattended-upgrades apt-listchanges

	cat >/etc/apt/apt.conf.d/50unattended-upgrades <<'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF

	cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF

	systemctl enable unattended-upgrades 2>/dev/null || true
	systemctl restart unattended-upgrades 2>/dev/null || true

	register_result "UnattendedUpgrades" "OK" "Automatic security updates configured"
}

configure_fail2ban() {
	info "Installing and configuring fail2ban..."
	pkg_install fail2ban

	cat >/etc/fail2ban/jail.local <<'JAIL'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5

[sshd]
enabled = true
port = ssh
logpath = %(sshd_log)s
maxretry = 3

[apache-auth]
enabled = true
port = http,https
logpath = %(apache_error_log)s
maxretry = 5

[apache-badbots]
enabled = true
port = http,https
logpath = %(apache_access_log)s
maxretry = 2

[nginx-http-auth]
enabled = true
port = http,https
logpath = %(nginx_error_log)s
maxretry = 5
JAIL

	if command -v nginx >/dev/null 2>&1 && systemctl is-active --quiet nginx 2>/dev/null; then
		sed -i 's/^\[apache-auth\]/[nginx-http-auth]/' /etc/fail2ban/jail.local
	fi

	systemctl enable fail2ban
	systemctl restart fail2ban

	register_result "Fail2ban" "OK" "fail2ban installed and configured"
}

configure_ufw_rate_limit() {
	info "Configuring UFW rate limiting..."

	if ! command -v ufw >/dev/null 2>&1; then
		pkg_install ufw
	fi

	ufw --force reset 2>/dev/null || true

	ufw default deny incoming
	ufw default allow outgoing

	ufw allow OpenSSH

	ufw limit 80/tcp
	ufw limit 443/tcp

	ufw --force enable 2>/dev/null || true

	register_result "UFW" "OK" "UFW rate limiting configured (SSH, HTTP, HTTPS)"
}

run_security_hardening() {
	info "Applying security hardening..."

	configure_unattended_upgrades
	configure_ufw_rate_limit
	configure_fail2ban

	register_result "Security" "OK" "Security hardening applied"
}
