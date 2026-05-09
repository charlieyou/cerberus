BIN := bin/cerberus
GO_SOURCES := $(shell find cmd internal -type f -name '*.go' 2>/dev/null)

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
	@echo "structural lint: to be implemented in Epic G"

fixtures-refresh:
	@echo "fixtures-refresh: to be implemented in Epic G"
