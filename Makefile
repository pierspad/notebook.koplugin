# Notebook, a KOReader plugin.
#
# Everything the project does to itself is a target here, so that the git hooks,
# CI and a person at a terminal all run the same commands. `make` on its own
# checks and packages, which is what a release does.
#
# make test        run the test bench
# make lint        luacheck, if it is installed
# make verify      lint + test: what must pass before anything leaves the machine
# make package     build the installable zip in build/
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

.PHONY: all test lint verify package clean install-hooks deploy version

all: verify package

test:
	@cd lua && for s in $(SUITES); do \
	    printf '%-10s ' "$$s"; \
	    luajit spec/$$s.lua > /tmp/notebook-spec.$$s 2>&1 \
	        && tail -1 /tmp/notebook-spec.$$s \
	        || { echo FAILED; cat /tmp/notebook-spec.$$s; exit 1; }; \
	done

lint:
	@if command -v luacheck >/dev/null 2>&1; then \
	    luacheck lua; \
	else \
	    echo "luacheck not installed, skipping (CI runs it)"; \
	fi

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

version:
	@echo $(VERSION)

clean:
	@rm -rf $(BUILD)

install-hooks:
	@git config core.hooksPath .githooks
	@echo "git will run the hooks in .githooks"

deploy:
	@tools/deploy.sh $(TARGET) $(FLAGS)
