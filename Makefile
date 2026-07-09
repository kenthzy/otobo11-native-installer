SHELL := /usr/bin/env bash
SH_FILES := $(shell find . -name '*.sh' -not -path './.git/*' | sort)

.PHONY: lint format format-check check

lint:
	shellcheck $(SH_FILES)

format:
	shfmt -w -i 4 -ci $(SH_FILES)

format-check:
	shfmt -d -i 4 -ci $(SH_FILES)

check: lint format-check