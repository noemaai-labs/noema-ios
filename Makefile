# Makefile
# Simple Makefile helpers for Noema

.PHONY: spm-refresh spm-reset resolve lint lint-localization docs-runtime lint-docs-runtime

# Remove .build cache and regenerate pins/resolved
spm-refresh:
	rm -rf .build
	rm -f Package.resolved
	swift package resolve

# Clean SPM artifacts and derived data (Xcode)
spm-reset:
	rm -rf .build
	rm -f Package.resolved
	rm -rf ~/Library/Developer/Xcode/DerivedData/*
	swift package reset

resolve:
	swift package resolve

lint: lint-localization lint-docs-runtime

lint-localization:
	python3 scripts/lint-localizations.py

docs-runtime:
	python3 scripts/generate-runtime-docs.py

lint-docs-runtime:
	python3 scripts/generate-runtime-docs.py --check
