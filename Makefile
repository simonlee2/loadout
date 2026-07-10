# Loadout developer conveniences.
#
#   make dev-install   Build the app bundle (Debug) and install it to
#                      /Applications/Loadout-dev.app — the -dev suffix keeps it
#                      apart from a released Loadout.app.
#   make dev-app       Just build the Debug .app (no install).
#
# The .xcodeproj is generated from App/project.yml by xcodegen (git-ignored,
# never edited by hand); the explicit shared `Loadout` scheme builds the .app,
# not the SwiftPM CLI executable of the same name. See docs/app-bundle.md.

APP_DIR      := App
DERIVED_DATA := build/dd
BUILT_APP    := $(APP_DIR)/$(DERIVED_DATA)/Build/Products/Debug/Loadout.app
DEV_APP      := /Applications/Loadout-dev.app

.PHONY: help dev-install dev-app

help:
	@grep -E '^#   make' Makefile | sed 's/^#   //'

dev-app:
	cd $(APP_DIR) && xcodegen generate --spec project.yml
	cd $(APP_DIR) && xcodebuild \
		-project LoadoutApp.xcodeproj \
		-scheme Loadout \
		-configuration Debug \
		-derivedDataPath $(DERIVED_DATA) \
		build
	@echo "Built $(BUILT_APP)"

dev-install: dev-app
	rm -rf "$(DEV_APP)"
	ditto "$(BUILT_APP)" "$(DEV_APP)"
	@echo "Installed $(DEV_APP) — launch it from Spotlight as \"Loadout-dev\"."
