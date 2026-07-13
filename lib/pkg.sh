#!/usr/bin/env bash

PKG_MANAGER=""
PKG_UPDATE=""
PKG_INSTALL=""
PKG_REMOVE=""
OS_ID=""
OS_VERSION=""
OS_NAME=""

detect_os() {
	if [[ -f /etc/os-release ]]; then
		source /etc/os-release
		OS_ID="$ID"
		OS_VERSION="$VERSION_ID"
		OS_NAME="$PRETTY_NAME"
	elif [[ -f /etc/debian_version ]]; then
		OS_ID="debian"
		OS_VERSION=$(cat /etc/debian_version)
		OS_NAME="Debian $OS_VERSION"
	else
		OS_ID="unknown"
		OS_VERSION=""
		OS_NAME="Unknown"
	fi

	case "$OS_ID" in
	ubuntu | debian)
		PKG_MANAGER="apt"
		PKG_UPDATE="apt-get update"
		PKG_INSTALL="DEBCONF_FRONTEND=noninteractive apt-get install -y"
		PKG_REMOVE="apt-get remove -y"
		;;
	*)
		PKG_MANAGER=""
		PKG_UPDATE=""
		PKG_INSTALL=""
		PKG_REMOVE=""
		;;
	esac

	echo "$OS_ID $OS_VERSION"
}

pkg_update() {
	if [[ -z "$PKG_MANAGER" ]]; then
		detect_os
	fi
	if [[ -z "$PKG_MANAGER" ]]; then
		die "Unsupported OS: $OS_NAME"
	fi
	$PKG_UPDATE "$@" || true
}

pkg_install() {
	if [[ -z "$PKG_MANAGER" ]]; then
		detect_os
	fi
	if [[ -z "$PKG_MANAGER" ]]; then
		die "Unsupported OS: $OS_NAME"
	fi
	$PKG_INSTALL "$@" || die "Failed to install packages: $*"
}

pkg_remove() {
	if [[ -z "$PKG_MANAGER" ]]; then
		detect_os
	fi
	if [[ -z "$PKG_MANAGER" ]]; then
		die "Unsupported OS: $OS_NAME"
	fi
	$PKG_REMOVE "$@" || true
}

os_is_debian_family() {
	if [[ -z "$OS_ID" ]]; then
		detect_os
	fi
	[[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" ]]
}

os_is_supported() {
	if [[ -z "$OS_ID" ]]; then
		detect_os
	fi
	case "$OS_ID" in
	ubuntu)
		case "$OS_VERSION" in
		22.04 | 24.04) return 0 ;;
		*) return 1 ;;
		esac
		;;
	debian)
		case "$OS_VERSION" in
		12*) return 0 ;;
		*) return 1 ;;
		esac
		;;
	*)
		return 1
		;;
	esac
}
