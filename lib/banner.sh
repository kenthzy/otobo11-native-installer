#!/usr/bin/env bash

show_banner() {

	[[ -n "$TERM" ]] && clear

	echo -e "${LIGHT_BLUE}"

	cat <<'EOF'
============================================================

                        OTOBOSuite

                     Version 1.0

        Automated by System Admin Kenneth

============================================================

 Environment

    Operating System : Ubuntu Server 24.04
    Web Server       : Apache
    Database         : MariaDB
    Installation     : Native

============================================================
EOF

	echo -e "${NC}"

}
