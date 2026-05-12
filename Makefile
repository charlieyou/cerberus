BIN := bin/cerberus
GO_SOURCES := $(shell find cmd internal -type f -name '*.go' 2>/dev/null)
INSTALL_ROOT ?= $(HOME)/.local/share/cerberus

.PHONY: build install test lint fixtures-refresh

build: $(BIN)

$(BIN): $(GO_SOURCES) go.mod go.sum
	@mkdir -p bin
	go build -buildvcs=false -tags netgo -o $(BIN) ./cmd/cerberus

install:
	@set -eu; \
	case "$(INSTALL_ROOT)" in ""|/) echo "refusing unsafe INSTALL_ROOT=$(INSTALL_ROOT)" >&2; exit 2;; esac; \
	stage=$$(mktemp -d "$${TMPDIR:-/tmp}/cerberus-install.XXXXXX"); \
	trap 'rm -rf "$$stage"' EXIT HUP INT TERM; \
	tar -cf - . | tar -x -C "$$stage"; \
	$(MAKE) -C "$$stage" build; \
	parent=$$(dirname -- "$(INSTALL_ROOT)"); \
	mkdir -p "$$parent"; \
	rm -rf "$(INSTALL_ROOT)"; \
	mv "$$stage" "$(INSTALL_ROOT)"; \
	trap - EXIT HUP INT TERM; \
	echo "installed cerberus working tree to $(INSTALL_ROOT)"; \
	echo "add $(INSTALL_ROOT)/bin to PATH before other cerberus installs"

test:
	go test ./...

lint:
	go vet ./...
	go run ./internal/lint/zerobash
	@! grep -RIl 'task-completed-hook\|teammate-idle-hook\|run-team' skills hooks agents bin 2>/dev/null
	@! grep -RIl 'bin/review-gate-models\.sh\|bin/review-gate' skills --include 'SKILL.md' 2>/dev/null
	@for skill in $$(find skills -name SKILL.md -print); do grep -q 'bin/cerberus' "$$skill" || { echo "$$skill: missing bin/cerberus reference"; exit 1; }; done
	go run ./internal/lint/r3sot
	go run ./internal/lint/bootstrapdrift

fixtures-refresh:
	@tmp=$$(mktemp -d); trap 'rm -rf "$$tmp"' EXIT; go build -o "$$tmp/fixtures-refresh" ./tests/fixtures/refresh.go; "$$tmp/fixtures-refresh"
