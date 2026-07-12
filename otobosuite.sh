#!/usr/bin/env bash

#############################################
# OTOBOSuite - OTOBO Management Suite
# Main Menu Launcher
#############################################

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

show_menu_banner() {
    clear
    echo -e "${LIGHT_BLUE}"
    echo "============================================================"
    echo
    echo "                        OTOBOSuite"
    echo
    echo "                     Version 1.0"
    echo
    echo "        Automated by System Admin Kenneth"
    echo
    echo "============================================================"
    echo -e "${NC}"
}

show_menu() {
    echo
    echo " What would you like to do?"
    echo
    echo "    1) Install OTOBO          -- Fresh installation (full stack)"
    echo "    2) Repair OTOBO           -- Diagnose and fix issues"
    echo "    3) Verify OTOBO           -- Post-install health check"
    echo "    4) Uninstall OTOBO        -- Remove OTOBO and components"
    echo "    5) Upgrade OTOBO          -- Coming soon"
    echo "    6) Configure SSL          -- Coming soon"
    echo "    7) Exit"
    echo
    read -rp " Enter your choice [1-7]: " choice
    echo
}

run_script() {
    local script="$1"
    local label="$2"

    if [[ ! -f "$SCRIPT_DIR/$script" ]]; then
        echo -e "${RED}[FAIL]${NC} $script not found."
        echo
        read -rp "Press Enter to return to menu..."
        return
    fi

    echo -e "${LIGHT_BLUE}Launching: $label${NC}"
    echo
    sleep 1

    if [[ "$(id -u)" -ne 0 && "$script" != "verify.sh" ]]; then
        echo -e "${YELLOW}This action requires root privileges. Re-running with sudo...${NC}"
        echo
        sudo "$SCRIPT_DIR/$script"
    else
        "$SCRIPT_DIR/$script"
    fi

    echo
    read -rp "Press Enter to return to menu..."
}

main() {
    source "$SCRIPT_DIR/lib/colors.sh"

    while true; do
        show_menu_banner
        show_menu

        case "$choice" in
            1) run_script "install.sh" "Install OTOBO" ;;
            2) run_script "repair.sh" "Repair OTOBO" ;;
            3) run_script "verify.sh" "Verify OTOBO" ;;
            4) run_script "uninstall.sh" "Uninstall OTOBO" ;;
            5)
                echo -e "${YELLOW}Upgrade feature is coming soon.${NC}"
                echo
                read -rp "Press Enter to return to menu..."
                ;;
            6)
                echo -e "${YELLOW}SSL/HTTPS configuration is coming soon.${NC}"
                echo
                read -rp "Press Enter to return to menu..."
                ;;
            7)
                echo -e "${GREEN}Goodbye.${NC}"
                echo
                exit 0
                ;;
            *)
                echo -e "${RED}Invalid choice. Please enter 1-7.${NC}"
                echo
                read -rp "Press Enter to continue..."
                ;;
        esac
    done
}

main "$@"
