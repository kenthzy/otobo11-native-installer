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
		PKG_INSTALL="apt-get install -y"
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

APT_PROXY_OPTS=()

pkg_init_proxy() {
	APT_PROXY_OPTS=()
	if [[ -n "${APT_PROXY:-}" ]]; then
		APT_PROXY_OPTS=("-o" "Acquire::http::Proxy=${APT_PROXY}" "-o" "Acquire::https::Proxy=${APT_PROXY}")
	fi
}

pkg_update() {
	if [[ -z "$PKG_MANAGER" ]]; then
		detect_os
	fi
	if [[ -z "$PKG_MANAGER" ]]; then
		die "Unsupported OS: $OS_NAME"
	fi
	pkg_init_proxy
	$PKG_UPDATE "${APT_PROXY_OPTS[@]}" "$@" || true
}

pkg_install() {
	if [[ -z "$PKG_MANAGER" ]]; then
		detect_os
	fi
	if [[ -z "$PKG_MANAGER" ]]; then
		die "Unsupported OS: $OS_NAME"
	fi
	pkg_init_proxy
	DEBCONF_FRONTEND=noninteractive $PKG_INSTALL "${APT_PROXY_OPTS[@]}" "$@" || die "Failed to install packages: $*"
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
