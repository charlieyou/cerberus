package hook

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/charlieyou/cerberus/internal/state"
	"github.com/charlieyou/cerberus/internal/telemetry"
)

const (
	PollIntervalSeconds = 3
	MaxWaitSeconds      = 1800
)

func PollGateState(path string, pollInterval, maxWait time.Duration) error {
	if path == "" {
		return fmt.Errorf("gate state path is required")
	}
	if pollInterval <= 0 {
		pollInterval = PollIntervalSeconds * time.Second
	}
	if maxWait <= 0 {
		maxWait = MaxWaitSeconds * time.Second
	}

	deadline := time.NewTimer(maxWait)
	defer deadline.Stop()

	var tick <-chan time.Time
	ticker := time.NewTicker(pollInterval)
	defer ticker.Stop()
	blocked := false

	for {
		gate, err := state.ReadGateState(path)
		if err != nil {
			if errors.Is(err, os.ErrNotExist) {
				writeHookEvent(path, telemetry.EventHookAllowed, nil)
				return nil
			}
			if !blocked {
				blocked = true
				writeHookEvent(path, telemetry.EventHookBlocked, map[string]any{"error": err.Error()})
			}
			tick = ticker.C
			select {
			case <-deadline.C:
				return fmt.Errorf("timed out waiting for readable gate state %s after %s: %w", path, maxWait, err)
			case <-tick:
			}
			continue
		}
		if gate.Status == state.StatusResolved {
			writeHookEvent(path, telemetry.EventHookAllowed, map[string]any{"status": gate.Status})
			return nil
		}
		if gate.Status == state.StatusPending && !blocked {
			blocked = true
			writeHookEvent(path, telemetry.EventHookBlocked, map[string]any{"status": gate.Status})
		}

		tick = ticker.C
		select {
		case <-deadline.C:
			return fmt.Errorf("timed out waiting for gate state %s to resolve after %s", path, maxWait)
		case <-tick:
		}
	}
}

func writeHookEvent(gatePath, eventName string, payload map[string]any) {
	if payload == nil {
		payload = map[string]any{}
	}
	payload["gate_state_path"] = gatePath
	_ = telemetry.WriteEvent(filepath.Dir(gatePath), telemetry.Event{
		Event:     eventName,
		Timestamp: time.Now().UTC(),
		Payload:   payload,
	})
}
