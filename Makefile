SHELL := /bin/zsh

DMG_VARIANT ?= native
DMG_TEST_MODE ?= full

.PHONY: dmg

# Build a reproducible offline-only DMG from the current clean commit.
# Supported variants: native, apple-silicon, intel, all.
dmg:
	@set -euo pipefail; \
	case "$(DMG_VARIANT)" in \
		native|apple-silicon|intel|all) ;; \
		*) print -u2 "DMG_VARIANT must be native, apple-silicon, intel, or all"; exit 2 ;; \
	esac; \
	case "$(DMG_TEST_MODE)" in \
		full|targeted) ;; \
		*) print -u2 "DMG_TEST_MODE must be full or targeted"; exit 2 ;; \
	esac; \
	if [[ -n "$$(git status --porcelain --untracked-files=all)" ]]; then \
		print -u2 "make dmg requires a clean checkout; commit and push first"; \
		exit 1; \
	fi; \
	source_commit="$$(git rev-parse HEAD)"; \
	export SAYALL_OFFLINE_DMG_TEST_MODE="$(DMG_TEST_MODE)"; \
	./scripts/build-offline-dmg.sh "$(DMG_VARIANT)"; \
	version="$$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - Resources/Info.plist)"; \
	build_number="$$(/usr/bin/plutil -extract CFBundleVersion raw -o - Resources/Info.plist)"; \
	case "$(DMG_VARIANT)" in \
		native) \
			if [[ "$$(/usr/bin/uname -m)" == arm64 ]]; then \
				assets=("dist/SayAll-$$version-$$build_number.dmg"); \
			else \
				assets=("dist/intel/SayAll-$$version-$$build_number-Intel.dmg"); \
			fi ;; \
		apple-silicon) assets=("dist/SayAll-$$version-$$build_number.dmg") ;; \
		intel) assets=("dist/intel/SayAll-$$version-$$build_number-Intel.dmg") ;; \
		all) assets=( \
			"dist/SayAll-$$version-$$build_number.dmg" \
			"dist/intel/SayAll-$$version-$$build_number-Intel.dmg" \
		) ;; \
	esac; \
	/bin/mkdir -p build; \
	for asset in "$${assets[@]}"; do \
		./scripts/verify-release-asset-source.sh \
			--asset "$$asset" \
			--expected-commit "$$source_commit"; \
		destination="build/$${asset:t}"; \
		/usr/bin/ditto --norsrc --noextattr --noqtn --noacl "$$asset" "$$destination"; \
		/usr/bin/shasum -a 256 "$$destination" > "$$destination.sha256"; \
		print "DMG_READY asset=$$destination commit=$$source_commit"; \
	done
