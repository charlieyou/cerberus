BIN := bin/cerberus
GO_SOURCES := $(shell find cmd internal -type f -name '*.go' 2>/dev/null)

.PHONY: build install test lint fixtures-refresh

build: $(BIN)

$(BIN): $(GO_SOURCES) go.mod go.sum
	@mkdir -p bin
	go build -tags netgo -o $(BIN) ./cmd/cerberus

install:
	go install ./cmd/cerberus

test:
	go test ./...

lint:
	go vet ./...
	go run ./tools/r3lint
	go test ./tests/integration/cleanup_invariants_test.go

fixtures-refresh:
	@tmp=$$(mktemp -d); trap 'rm -rf "$$tmp"' EXIT; go build -o "$$tmp/fixtures-refresh" ./tests/fixtures/refresh.go; "$$tmp/fixtures-refresh"
