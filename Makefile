# Makefile for MAMP 6.9 Custom PHP Build Scripts

SHELL := /bin/bash
.DEFAULT_GOAL := help

VERSIONS ?=
BROWSCAP_TYPE ?= lite
FORCE ?= 0

.PHONY: help all zlib deps php ext-deps ext ext86 extra-ext legacy legacy-php legacy-ext ini conf config browscap update-browscap browscap-lite browscap-special browscap-full package dist

help:
	@echo "MAMP 6.9 Custom PHP Builder"
	@echo ""
	@echo "Targets:"
	@echo "  make all              Run full modern build pipeline (deps, php, ext, extra-ext, ini, browscap)"
	@echo "  make zlib             Build zlib 1.3.2 into /Applications/MAMP/Library"
	@echo "  make deps             Build zlib + Phase A MAMP Library dependencies (OpenSSL 3, curl, etc.)"
	@echo "  make php              Compile and install PHP versions (override with VERSIONS=\"8.6.0\")"
	@echo "  make ext-deps         Build static C library dependencies for PECL extensions"
	@echo "  make ext              Build PECL extensions for PHP 8.2-8.5 and 8.6"
	@echo "  make ext86            Build PECL extensions for PHP 8.6 only"
	@echo "  make extra-ext        Build optional extensions (ffi, dba, gmp, mongodb, amqp, protobuf)"
	@echo "  make legacy           Build legacy EOL PHP 5.6 & 7.4 and their PECL extensions"
	@echo "  make ini              Generate php.ini, pear.conf, and php.ini.temp for installed versions"
	@echo "  make browscap         Update /Applications/MAMP/bin/php/browscap.ini (uses BROWSCAP_TYPE=lite|special|full)"
	@echo "  make browscap-lite    Update browscap.ini with Lite edition (Lite_PHP_BrowsCapINI)"
	@echo "  make browscap-special Update browscap.ini with Special edition (PHP_BrowsCapINI)"
	@echo "  make browscap-full    Update browscap.ini with Full edition (Full_PHP_BrowsCapINI)"
	@echo "  make package          Package installed PHP builds into dist/ tarballs with SHA-256 checksums"
	@echo ""
	@echo "Variables:"
	@echo "  VERSIONS=\"...\"        Space-separated PHP versions for php/package targets"
	@echo "  BROWSCAP_TYPE=lite    browscap edition: lite (default), special, or full"
	@echo "  FORCE=1               Force browscap download even when version matches upstream"

all: deps php ext extra-ext ini browscap

zlib:
	bash build-zlib-mamp.sh

deps: zlib
	bash build-deps-mamp.sh all

php:
	./compile-all-php.sh $(VERSIONS)

ext-deps:
	bash build-mamp-ext.sh deps

ext: ext-deps
	bash build-mamp-ext.sh ext
	bash build-mamp-ext.sh ext86

ext86:
	bash build-mamp-ext.sh ext86

extra-ext:
	bash build-extra-ext.sh

legacy: legacy-php legacy-ext

legacy-php:
	bash build-legacy-php.sh all

legacy-ext:
	bash build-legacy-ext.sh
	bash build-legacy-ext56.sh

ini conf config:
	python3 configure-mamp-ini.py

browscap update-browscap:
	FORCE="$(FORCE)" bash update-browscap-mamp.sh "$(BROWSCAP_TYPE)"

browscap-lite:
	FORCE="$(FORCE)" bash update-browscap-mamp.sh lite

browscap-special:
	FORCE="$(FORCE)" bash update-browscap-mamp.sh special

browscap-full:
	FORCE="$(FORCE)" bash update-browscap-mamp.sh full

package dist:
	./package-mamp-php.sh $(VERSIONS)
