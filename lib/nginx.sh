#!/usr/bin/env bash

install_nginx() {
	info "Installing nginx..."
	pkg_install nginx

	success "nginx installed."

	info "Configuring nginx as reverse proxy to Starman..."

	cat >/etc/nginx/sites-available/otobo <<-'NGINX_CONF'
		upstream otobo_backend {
		    server 127.0.0.1:5000;
		}

		server {
		    listen 80;
		    server_name _;

		    client_max_body_size 64M;
		    proxy_read_timeout 120s;
		    proxy_send_timeout 120s;

		    location /otobo-web/ {
		        proxy_pass http://otobo_backend/otobo-web/;
		        proxy_set_header Host $host;
		        proxy_set_header X-Real-IP $remote_addr;
		        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
		        proxy_set_header X-Forwarded-Proto $scheme;
		    }

		    location / {
		        proxy_pass http://otobo_backend;
		        proxy_set_header Host $host;
		        proxy_set_header X-Real-IP $remote_addr;
		        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
		        proxy_set_header X-Forwarded-Proto $scheme;
		    }
		}
	NGINX_CONF

	rm -f /etc/nginx/sites-enabled/default
	ln -sf /etc/nginx/sites-available/otobo /etc/nginx/sites-enabled/

	if ! nginx -t 2>/dev/null; then
		register_result "Nginx" "FAIL" "nginx config syntax error"
		error "nginx configuration syntax error."
	fi

	systemctl enable nginx
	systemctl restart nginx

	register_result "Nginx" "PASS" "nginx reverse proxy configured for OTOBO"
	success "nginx configured as reverse proxy to Starman."
}
