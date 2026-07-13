#!/usr/bin/env bash

show_banner() {
	[[ -n "$TERM" ]] && clear

	local os_name="${OS_NAME:-Ubuntu Server 24.04}"

	echo -e "${LIGHT_BLUE}"

	cat <<EOF
============================================================

                      OTOBOSuite

                   Version 1.0

        Automated by System Admin Kenneth

============================================================

 Environment

    Operating System : ${os_name}
    Web Server       : Apache
    Database         : MariaDB
    Installation     : Native

============================================================
EOF

	echo -e "${NC}"
}
