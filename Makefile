.DEFAULT_GOAL := help

NIX ?= nix

# Passing a directory to nixfmt is deprecated, so the files are listed.
NIX_FILES = $(shell find . -name '*.nix' -not -path './.git/*')

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN { FS = ":.*?## " }; { printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2 }'

.PHONY: fmt
fmt: ## Format the Nix files
	$(NIX) run nixpkgs#nixfmt-rfc-style -- $(NIX_FILES)

.PHONY: lint
lint: ## Check formatting and shell scripts
	$(NIX) run nixpkgs#nixfmt-rfc-style -- --check $(NIX_FILES)
	$(NIX) run nixpkgs#shellcheck -- scripts/*.sh

.PHONY: check
check: ## Run the flake checks
	$(NIX) flake check --print-build-logs

.PHONY: build
build: ## Build the release-binary packages
	$(NIX) build --print-build-logs .#gno-tools .#gno-indexer

.PHONY: build-source
build-source: ## Build everything compiled from source (slow)
	$(NIX) build --print-build-logs .#gno-tools-source .#gno-contribs .#gno-faucet

.PHONY: update
update: ## Refresh versions/*.json from the newest upstream release
	./scripts/update-versions.sh

.PHONY: vendor-hash
vendor-hash: ## Record vendorHashes for the pinned gno ref
	./scripts/vendor-hash.sh

.PHONY: update-flake
update-flake: ## Update the flake inputs
	$(NIX) flake update
