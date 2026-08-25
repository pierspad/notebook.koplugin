# Notebook, a KOReader plugin.
#
# Everything the project does to itself is a target here, so that the git hooks,
# CI and a person at a terminal all run the same commands. `make` on its own
# checks and packages, which is what a release does.
#
# make test        run the test bench
# make lint        luacheck
# make verify      lint + test
# make package     build the installable zip in build/
# make ci          everything CI runs -- what the pre-push hook uses
# make install-hooks  point git at .githooks
# make deploy      copy onto a device (see tools/deploy.sh)

SHELL := /usr/bin/env bash

PLUGIN  := notebook.koplugin
VERSION := $(shell sed -n 's/.*version = "\(.*\)".*/\1/p' lua/_meta.lua)
BUILD   := build
STAGE   := $(BUILD)/$(PLUGIN)
ZIP     := $(BUILD)/$(PLUGIN)-$(VERSION).zip

# Every suite in the bench. Named rather than globbed: spec/ also holds the
# helpers the suites share and the two tools that render to a real file, and a
# glob would run those as though they were tests.
SUITES := run pages eraser palm safe i18n gallery shape lasso migration

.PHONY: all test lint verify package check-package ci clean install-hooks deploy version

all: verify package

test:
	@cd lua && for s in $(SUITES); do \
	    printf '%-10s ' "$$s"; \
	    luajit spec/$$s.lua > /tmp/notebook-spec.$$s 2>&1 \
	        && tail -1 /tmp/notebook-spec.$$s \
	        || { echo FAILED; cat /tmp/notebook-spec.$$s; exit 1; }; \
	done

# A check that skips itself when its tool is missing is not a check. This one
# used to say "luacheck not installed, skipping (CI runs it)" and return
# success, so the hooks passed, the push went out, and CI failed on seventeen
# warnings that had been sitting in the tree all along. Refusing to run is the
# only honest answer: it is one command to fix and it fails here instead of on
# GitHub.
lint:
	@command -v luacheck >/dev/null 2>&1 || { \
	    echo "luacheck is not installed, and lint cannot pass without it."; \
	    echo "  Arch:    sudo pacman -S luacheck"; \
	    echo "  Debian:  sudo apt install lua-check"; \
	    echo "  Any:     luarocks install luacheck"; \
	    exit 1; \
	}
	@luacheck lua

verify: lint test

# The package is the plugin directory and nothing else: no tests, no tooling.
# KOReader reads the .po catalogues at load, so those do ship.
package: $(ZIP)

$(ZIP): $(shell find lua -type f -not -path 'lua/spec/*')
	@rm -rf $(STAGE) $(BUILD)/*.zip
	@mkdir -p $(STAGE)
	@cp -r lua/. $(STAGE)/
	@rm -rf $(STAGE)/spec
	@cd $(BUILD) && zip -qr $(notdir $(ZIP)) $(PLUGIN)
	@rm -rf $(STAGE)
	@echo "built $(ZIP)"

# What the package must be true of before it is worth attaching to anything.
# Here rather than written out in the release workflow, so that the checks a
# release depends on are the same ones that run before a push.
check-package: package
	@set -euo pipefail; \
	unzip -tq $(ZIP); \
	unzip -l $(ZIP) | grep -q '$(PLUGIN)/main.lua' \
	    || { echo "$(ZIP) has no main.lua in it" >&2; exit 1; }; \
	unzip -l $(ZIP) | grep -q '$(PLUGIN)/_meta.lua' \
	    || { echo "$(ZIP) has no _meta.lua in it" >&2; exit 1; }; \
	unzip -l $(ZIP) | grep -q '$(PLUGIN)/locale/' \
	    || { echo "$(ZIP) has no translations in it" >&2; exit 1; }; \
	! unzip -l $(ZIP) | grep -q '$(PLUGIN)/spec/' \
	    || { echo "$(ZIP) carries the test bench" >&2; exit 1; }; \
	echo "$(ZIP) checks out"

# Everything CI does, in one target, so that "it passed here" and "it passed on
# GitHub" cannot mean different things. The workflows call this; so does the
# pre-push hook.
ci: verify check-package

version:
	@echo $(VERSION)

clean:
	@rm -rf $(BUILD)

install-hooks:
	@git config core.hooksPath .githooks
	@echo "git will run the hooks in .githooks"

deploy:
	@tools/deploy.sh $(TARGET) $(FLAGS)
