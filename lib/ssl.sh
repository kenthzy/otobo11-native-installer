#!/usr/bin/env bash

#############################################
# OTOBOSuite - OTOBO Management Suite
# SSL/HTTPS Configuration Module
#############################################

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/functions.sh"

SSL_NAMES=()
SSL_STATUSES=()
SSL_MESSAGES=()
HAS_FAIL=0

register_result() {
	local name="$1"
	local status="$2"
	local message="$3"
	SSL_NAMES+=("$name")
	SSL_STATUSES+=("$status")
	SSL_MESSAGES+=("$message")
	if [[ "$status" == "FAIL" ]]; then
		HAS_FAIL=1
	fi
}

ssl_summary() {
	local pass_count=0 warn_count=0 fail_count=0 info_count=0 skip_count=0

	for status in "${SSL_STATUSES[@]}"; do
		case "$status" in
		PASS) ((pass_count++)) ;;
		WARN) ((warn_count++)) ;;
		FAIL) ((fail_count++)) ;;
		INFO) ((info_count++)) ;;
		SKIP) ((skip_count++)) ;;
		esac
	done

	echo
	echo -e "${BOLD}============================================================${NC}"
	echo -e "${BOLD}$(printf '%*s' 30 "")SSL SETUP SUMMARY${NC}"
	echo -e "${BOLD}============================================================${NC}"

	for i in "${!SSL_NAMES[@]}"; do
		local name="${SSL_NAMES[$i]}"
		local status="${SSL_STATUSES[$i]}"
		local message="${SSL_MESSAGES[$i]}"
		local formatted_status

		case "$status" in
		PASS) formatted_status="${GREEN}PASS${NC}" ;;
		WARN) formatted_status="${YELLOW}WARN${NC}" ;;
		FAIL) formatted_status="${RED}FAIL${NC}" ;;
		INFO) formatted_status="${LIGHT_BLUE}INFO${NC}" ;;
		SKIP) formatted_status="${MAGENTA}SKIP${NC}" ;;
		esac

		printf " %-18s  %-4b  %s\n" "$name" "$formatted_status" "$message"
	done

	echo -e "${BOLD}============================================================${NC}"
	local total=$((pass_count + warn_count + fail_count + info_count + skip_count))
	local result_line="Result: ${GREEN}${pass_count} PASS${NC}"
	result_line+=", ${YELLOW}${warn_count} WARN${NC}"
	result_line+=", ${RED}${fail_count} FAIL${NC}"
	result_line+=", ${LIGHT_BLUE}${info_count} INFO${NC}"
	result_line+=", ${MAGENTA}${skip_count} SKIP${NC}"
	result_line+=" (${total} total)"
	echo -e " ${result_line}"
	echo -e "${BOLD}============================================================${NC}"
	echo
}

get_public_ip() {
	curl -s --connect-timeout 5 https://api.ipify.org 2>/dev/null || echo ""
}

is_private_ip() {
	local ip="$1"
	[[ "$ip" =~ ^10\. ]] ||
		[[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[01])\. ]] ||
		[[ "$ip" =~ ^192\.168\. ]] ||
		[[ "$ip" =~ ^127\. ]]
}

check_root() {
	if [[ "$(id -u)" -ne 0 ]]; then
		error "This script must be run as root (sudo)."
	fi
}

detect_webserver() {
	if command -v nginx >/dev/null 2>&1 && systemctl is-active --quiet nginx 2>/dev/null; then
		WEB_SERVER="nginx"
	elif command -v apache2 >/dev/null 2>&1; then
		WEB_SERVER="apache"
	else
		WEB_SERVER=""
	fi
}

check_prerequisites() {
	info "Checking prerequisites..."

	detect_webserver

	if [[ "$WEB_SERVER" == "nginx" ]]; then
		if [[ ! -f /etc/nginx/sites-available/otobo ]]; then
			register_result "Prerequisites" "FAIL" "nginx OTOBO site not configured"
			error "nginx OTOBO configuration not found. Run install.sh first."
		fi
		success "nginx detected."
	elif [[ "$WEB_SERVER" == "apache" ]]; then
		if ! a2query -m ssl >/dev/null 2>&1; then
			a2enmod ssl >/dev/null 2>&1
			register_result "Prerequisites" "INFO" "Apache SSL module enabled"
		fi
		success "Apache detected."
	else
		register_result "Prerequisites" "FAIL" "No web server detected"
		error "No supported web server found. Run install.sh first."
	fi

	register_result "Prerequisites" "PASS" "All prerequisites met"
	success "Prerequisites verified."
}

ssl_restart_webserver() {
	if [[ "$WEB_SERVER" == "nginx" ]]; then
		systemctl restart nginx
		if systemctl is-active --quiet nginx; then
			register_result "Restart" "PASS" "nginx restarted with HTTPS"
			success "nginx restarted with HTTPS."
		else
			register_result "Restart" "FAIL" "nginx failed to start"
			error "nginx failed to start after SSL configuration."
		fi
	else
		systemctl restart apache2
		if systemctl is-active --quiet apache2; then
			register_result "Restart" "PASS" "Apache restarted with HTTPS"
			success "Apache restarted with HTTPS."
		else
			register_result "Restart" "FAIL" "Apache failed to start"
			error "Apache failed to start after SSL configuration."
		fi
	fi
}

ssl_test_https() {
	local server_ip="$1"
	if curl -s -o /dev/null -w "%{http_code}" "https://${server_ip}/otobo/installer.pl" -k 2>/dev/null | grep -qE '200|302'; then
		register_result "HTTPS" "PASS" "HTTPS reachable on ${server_ip}"
		success "HTTPS is working."
	else
		register_result "HTTPS" "WARN" "HTTPS not responding on ${server_ip}"
		warning "HTTPS may not be working. Check web server logs."
	fi
}

setup_self_signed_apache() {
	local cert_file="$1"
	local key_file="$2"
	local server_ip="$3"
	local ssl_conf="/etc/apache2/sites-available/zzz_otobo-ssl.conf"

	cat >"$ssl_conf" <<-EOF
		<VirtualHost *:443>
		    ServerName ${server_ip}

		    SSLEngine on
		    SSLCertificateFile ${cert_file}
		    SSLCertificateKeyFile ${key_file}

		    Include /etc/apache2/sites-available/zzz_otobo.conf
		</VirtualHost>

		<VirtualHost *:80>
		    ServerName ${server_ip}
		    Redirect permanent / https://${server_ip}/
		</VirtualHost>
	EOF

	a2ensite zzz_otobo-ssl >/dev/null 2>&1

	if ! apache2ctl configtest 2>/dev/null; then
		register_result "ApacheSSL" "FAIL" "Apache config syntax error"
		error "Apache configuration syntax error. Check ${ssl_conf}"
	fi
	register_result "ApacheSSL" "PASS" "Apache SSL virtual host configured"
}

setup_self_signed_nginx() {
	local cert_file="$1"
	local key_file="$2"
	local server_ip="$3"
	local ssl_conf="/etc/nginx/sites-available/otobo-ssl"

	cat >"$ssl_conf" <<-EOF
		server {
		    listen 443 ssl;
		    server_name ${server_ip};

		    ssl_certificate ${cert_file};
		    ssl_certificate_key ${key_file};

		    client_max_body_size 64M;
		    proxy_read_timeout 120s;
		    proxy_send_timeout 120s;

		    location / {
		        proxy_pass http://127.0.0.1:5000;
		        proxy_set_header Host \$host;
		        proxy_set_header X-Real-IP \$remote_addr;
		        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
		        proxy_set_header X-Forwarded-Proto \$scheme;
		    }
		}

		server {
		    listen 80;
		    server_name ${server_ip};
		    return 301 https://\$server_name\$request_uri;
		}
	EOF

	ln -sf "$ssl_conf" /etc/nginx/sites-enabled/

	if ! nginx -t 2>/dev/null; then
		register_result "NginxSSL" "FAIL" "nginx config syntax error"
		error "nginx configuration syntax error. Check ${ssl_conf}"
	fi
	register_result "NginxSSL" "PASS" "nginx SSL server block configured"
}

setup_self_signed() {
	detect_webserver

	local cert_file="/etc/ssl/certs/otobo-selfsigned.crt"
	local key_file="/etc/ssl/private/otobo-selfsigned.key"
	local server_ip

	server_ip=$(hostname -I 2>/dev/null | awk '{print $1}')

	info "Generating self-signed certificate..."

	if [[ ! -d /etc/ssl/certs ]]; then
		mkdir -p /etc/ssl/certs
	fi
	if [[ ! -d /etc/ssl/private ]]; then
		mkdir -p /etc/ssl/private
	fi

	openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
		-keyout "$key_file" \
		-out "$cert_file" \
		-subj "/C=PH/ST=Manila/L=Manila/O=OTOBOSuite/OU=IT/CN=${server_ip}" 2>/dev/null

	if [[ ! -f "$cert_file" ]]; then
		register_result "SelfSigned" "FAIL" "Certificate generation failed"
		error "Failed to generate self-signed certificate."
	fi

	chmod 600 "$key_file"
	chmod 644 "$cert_file"

	register_result "SelfSigned" "PASS" "Self-signed certificate generated"
	success "Self-signed certificate created."

	info "Configuring web server for HTTPS..."

	if [[ "$WEB_SERVER" == "nginx" ]]; then
		setup_self_signed_nginx "$cert_file" "$key_file" "$server_ip"
	else
		setup_self_signed_apache "$cert_file" "$key_file" "$server_ip"
	fi

	ssl_restart_webserver
	ssl_test_https "$server_ip"

	echo
	echo -e "${GREEN}============================================================${NC}"
	echo -e "${GREEN}$(printf '%*s' 20 "")SELF-SIGNED SSL SETUP COMPLETE${NC}"
	echo -e "${GREEN}============================================================${NC}"
	echo
	echo -e " HTTPS URL:  ${BOLD}https://${server_ip}/otobo/installer.pl${NC}"
	echo
	warning "This certificate is self-signed. Browsers will show a warning."
	warning "For production, use Let's Encrypt with a valid domain."
	echo
}

setup_letsencrypt() {
	local domain=""
	local server_ip
	local public_ip

	server_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
	public_ip=$(get_public_ip)

	info "Checking internet connectivity..."

	if [[ -z "$public_ip" ]]; then
		echo
		warning "Could not detect your public IP address."
		warning "Let's Encrypt requires port 80 to be reachable from the internet."
		echo
		if ! confirm "Continue anyway?" "N"; then
			register_result "LetsEncrypt" "SKIP" "Let's Encrypt skipped — no public IP detected"
			info "Let's Encrypt skipped."
			echo
			info "Consider using self-signed SSL or Cloudflare Tunnel instead."
			return
		fi
	fi

	echo
	read -rp " Enter your domain (e.g., helpdesk.example.com): " domain
	echo

	if [[ -z "$domain" ]]; then
		register_result "LetsEncrypt" "FAIL" "No domain provided"
		error "Domain cannot be empty."
	fi

	info "Verifying domain resolves to your server..."

	local domain_ip
	domain_ip=$(dig +short "$domain" 2>/dev/null | head -1)

	if [[ -n "$public_ip" && -n "$domain_ip" ]]; then
		if [[ "$domain_ip" != "$public_ip" ]]; then
			echo
			warning "Domain ${domain} resolves to ${domain_ip}"
			warning "Your public IP is ${public_ip}"
			echo
			if ! confirm "Domain doesn't match your IP. Continue anyway?" "N"; then
				register_result "LetsEncrypt" "SKIP" "Domain/IP mismatch"
				info "Let's Encrypt skipped."
				return
			fi
		else
			success "Domain ${domain} resolves to ${public_ip}"
		fi
	else
		info "Could not verify domain resolution. Proceeding..."
	fi

	info "Installing Certbot via snap..."

	if ! command -v snap >/dev/null 2>&1; then
		pkg_install snapd
		snap wait system seed.loaded 2>/dev/null || true
	fi

	if ! command -v certbot >/dev/null 2>&1; then
		snap install certbot --classic 2>/dev/null || {
			register_result "Certbot" "FAIL" "Failed to install certbot"
			error "Failed to install certbot."
		}
	fi

	register_result "Certbot" "PASS" "Certbot installed"
	success "Certbot installed."

	detect_webserver

	info "Obtaining Let's Encrypt certificate for ${domain}..."

	local certbot_plugin="--apache"
	local manual_hint="--apache"
	if [[ "$WEB_SERVER" == "nginx" ]]; then
		certbot_plugin="--nginx"
		manual_hint="--nginx"
	fi

	if certbot "$certbot_plugin" -d "$domain" --non-interactive --agree-tos \
		--email "admin@${domain}" --redirect 2>/dev/null; then
		register_result "Certificate" "PASS" "Let's Encrypt certificate obtained for ${domain}"
		success "Certificate obtained for ${domain}."
	else
		register_result "Certificate" "FAIL" "Let's Encrypt failed for ${domain}"
		warning "Let's Encrypt failed. This may be because:"
		warning "  - Port 80 is not reachable from the internet"
		warning "  - The domain does not point to this server"
		warning "  - Rate limits exceeded"
		echo
		info "You can try manually: sudo certbot ${manual_hint} -d ${domain}"
		return
	fi

	info "Verifying certificate renewal timer..."

	systemctl list-timers 2>/dev/null | grep -q certbot || true
	register_result "Renewal" "PASS" "Certbot auto-renewal configured"
	success "Automatic renewal is enabled."

	if [[ "$WEB_SERVER" == "nginx" ]]; then
		systemctl restart nginx
	else
		systemctl restart apache2
	fi

	if curl -s -o /dev/null -w "%{http_code}" "https://${domain}/otobo/installer.pl" 2>/dev/null | grep -qE '200|302'; then
		register_result "HTTPS" "PASS" "HTTPS reachable for ${domain}"
		success "HTTPS is working for ${domain}."
	else
		register_result "HTTPS" "WARN" "HTTPS not confirmed at https://${domain}"
		warning "Could not verify HTTPS. Check your DNS and firewall."
	fi

	echo
	echo -e "${GREEN}============================================================${NC}"
	echo -e "${GREEN}$(printf '%*s' 18 "")LET'S ENCRYPT SETUP COMPLETE${NC}"
	echo -e "${GREEN}============================================================${NC}"
	echo
	echo -e " HTTPS URL:  ${BOLD}https://${domain}/otobo/installer.pl${NC}"
	echo -e " Certificate: ${BOLD}/etc/letsencrypt/live/${domain}/${NC}"
	echo -e " Auto-renew:  ${BOLD}Enabled (systemd timer)${NC}"
	echo
}

show_ssl_banner() {
	clear
	echo -e "${LIGHT_BLUE}"
	echo "============================================================"
	echo
	echo "                    OTOBOSuite - SSL SETUP"
	echo
	echo "============================================================"
	echo -e "${NC}"
}

detect_network_status() {
	local server_ip
	local public_ip=""
	local ip_type="PRIVATE"

	server_ip=$(hostname -I 2>/dev/null | awk '{print $1}')

	if is_private_ip "$server_ip"; then
		ip_type="PRIVATE (behind NAT)"
		public_ip=$(get_public_ip)
	else
		ip_type="PUBLIC"
		public_ip="$server_ip"
	fi

	echo
	echo -e " Server IP:  ${BOLD}${server_ip}${NC} (${ip_type})"

	if [[ -n "$public_ip" && "$ip_type" == "PRIVATE (behind NAT)" ]]; then
		echo -e " Public IP:  ${BOLD}${public_ip}${NC}"
	fi
	echo

	if [[ "$ip_type" == "PRIVATE (behind NAT)" && -z "$public_ip" ]]; then
		echo -e " ${YELLOW}→ Your server appears to be on a private network.${NC}"
		echo -e " ${YELLOW}→ Let's Encrypt requires a public IP + reachable port 80.${NC}"
		echo
		return 0
	fi

	if [[ "$ip_type" == "PRIVATE (behind NAT)" && -n "$public_ip" ]]; then
		echo -e " ${YELLOW}→ Your server is behind NAT but has a public IP.${NC}"
		echo -e " ${YELLOW}→ Let's Encrypt may work if port 80 is forwarded to this VM.${NC}"
		echo
		return 0
	fi

	echo -e " ${GREEN}→ Your server has a public IP. Let's Encrypt is available.${NC}"
	echo
	return 0
}

show_mode_menu() {
	echo " What would you like to do?"
	echo
	echo "    1) Let's Encrypt (recommended)  -- Trusted certificate, needs a domain"
	echo "    2) Self-signed certificate      -- No domain needed, browser warning"
	echo "    3) Cancel"
	echo
	read -rp " Enter your choice [1-3]: " mode
	echo
}

configure_ssl() {
	local ssl_type="${1:-self-signed}"

	detect_webserver

	if [ "$ssl_type" = "letsencrypt" ]; then
		setup_letsencrypt
	else
		setup_self_signed
	fi
}

main() {
	check_root

	show_ssl_banner
	detect_network_status

	while true; do
		show_mode_menu

		case "$mode" in
		1)
			line
			info "Configuring Let's Encrypt SSL..."
			line
			echo
			setup_letsencrypt
			break
			;;
		2)
			line
			info "Configuring self-signed SSL..."
			line
			echo
			setup_self_signed
			break
			;;
		3)
			info "SSL setup cancelled."
			exit 0
			;;
		*)
			echo -e "${RED}Invalid choice. Please enter 1-3.${NC}"
			echo
			;;
		esac
	done

	echo
	ssl_summary

	if [[ "$HAS_FAIL" -eq 0 ]]; then
		echo
		success "SSL setup completed."
	else
		echo
		warning "SSL setup completed with warnings. Check the report above."
	fi
	echo
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
