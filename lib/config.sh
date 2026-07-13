#!/usr/bin/env bash

#############################################
# OTOBOSuite - OTOBO Management Suite
# Configuration File Module
# Reads /etc/otobo-installer.conf for
# silent/unattended installations
#############################################

CONFIG_FILE="/etc/otobo-installer.conf"

load_config() {
	if [[ -f "$CONFIG_FILE" ]]; then
		# shellcheck disable=SC1090
		source "$CONFIG_FILE"
		return 0
	fi
	return 1
}

config_value() {
	local key="$1"
	local default="$2"
	local val

	val=$(eval "echo \${${key}:-}" 2>/dev/null)
	if [[ -n "$val" ]]; then
		echo "$val"
	else
		echo "$default"
	fi
}
