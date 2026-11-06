# Convenience targets. The real work lives in scripts/.
SHELL := /bin/bash

PLUGIN_NAME := unraid-plugin-komari-agent

# Version of this plugin: the release date, YYYYMMDD. A second release on the
# same day adds a letter suffix, YYYYMMDD.a, YYYYMMDD.b and so on. The Unraid
# installer compares plugin versions with strcmp(), a byte wise string
# compare, so this format is what sorts in release order. Pin it to keep a
# build reproducible.
PLUGIN_VERSION ?= $(shell date +%Y%m%d)

# Version of the upstream komari-agent release that is bundled.
KOMARI_VERSION ?= 1.5.11
KOMARI_ARCH    ?= amd64

# Python interpreter. On Windows "python3" resolves to a WindowsApps stub that
# does not run, so allow an override: make build PYTHON=D:/Python312/python.exe
PYTHON ?= python3

DIST_DIR := dist
TXZ      := $(DIST_DIR)/$(PLUGIN_NAME)-$(PLUGIN_VERSION)-$(if $(filter amd64,$(KOMARI_ARCH)),x86_64,$(KOMARI_ARCH))-1.txz
PLG      := $(DIST_DIR)/$(PLUGIN_NAME).plg
ICON     := src/usr/local/emhttp/plugins/$(PLUGIN_NAME)/$(PLUGIN_NAME).png

export PYTHON

.PHONY: all build lint lint-repo lint-php lint-plg verify smoke check ci fetch icon clean distclean release help

all: build lint verify

## build: download, verify and package the plugin
build:
	PLUGIN_VERSION=$(PLUGIN_VERSION) KOMARI_VERSION=$(KOMARI_VERSION) KOMARI_ARCH=$(KOMARI_ARCH) ./scripts/build-plugin.sh

## lint-repo: source tree checks that need neither a build nor the network
lint-repo:
	./scripts/lint-repo.sh

## lint-php: the WebGUI PHP and .page sources
lint-php:
	$(PYTHON) scripts/check-php-syntax.py src/

## lint-plg: static checks on the generated .plg (needs a build first)
lint-plg:
	./scripts/lint-plg.sh

## lint: every static check. The .plg checks read dist/, so run `make build`
##       first on a clean tree; `make ci` orders the two correctly.
lint: lint-repo lint-php lint-plg

## verify: verify artifact hashes and layout
verify:
	./scripts/verify-release.sh

## smoke: run the packaged scripts under a fake root (needs a build first)
smoke:
	./scripts/smoke-test.sh

## check: is there a newer upstream komari-agent release? (needs network)
check:
	./scripts/check-upstream.sh

## ci: exactly what the verify job of the build workflow runs, in order.
##     lint-plg.sh reads dist/, so the build has to come before it; ordering
##     this as `lint build` failed on a clean checkout.
ci: lint-repo lint-php build lint-plg verify smoke
	@echo
	@echo "  ci checks passed"

## fetch: download and unpack the upstream binary only (audit/debug)
fetch:
	KOMARI_VERSION=$(KOMARI_VERSION) KOMARI_ARCH=$(KOMARI_ARCH) ./scripts/fetch-plugin.sh

## upstream: refresh plugin/upstream.lock from the GitHub Releases API
upstream:
	./scripts/update-upstream.sh $(KOMARI_VERSION)

## icon: regenerate the plugin icon
icon:
	$(PYTHON) scripts/make-icon.py $(ICON)

## release: print the gh command to publish the current build
release: build lint verify
	@echo
	@echo "Artifacts ready:"
	@echo "  $(TXZ)"
	@echo "  $(PLG)"
	@echo "  $(DIST_DIR)/$(PLUGIN_NAME)-proxy.plg"
	@echo
	@echo "Publish with:"
	@echo "  gh release create $(PLUGIN_VERSION) $(TXZ) $(DIST_DIR)/*.plg \\"
	@echo "    --title \"$(PLUGIN_NAME) $(PLUGIN_VERSION)\" \\"
	@echo "    --notes \"See CHANGELOG.md\""

## clean: remove build intermediates
clean:
	rm -rf pkg/work

## distclean: remove build intermediates and artifacts
distclean: clean
	rm -rf $(DIST_DIR) pkg

## help: list targets
help:
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/## /  /'
