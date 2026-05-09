package telemetry

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

const (
	EventBuildStarted               = "cerberus.build.started"
	EventBuildCompleted             = "cerberus.build.completed"
	EventBuildFailed                = "cerberus.build.failed"
	EventRosterSelected             = "cerberus.roster.selected"
	EventPreflightFailed            = "cerberus.preflight.failed"
	EventReviewSpawned              = "cerberus.review.spawned"
	EventReviewerSpawned            = "cerberus.reviewer.spawned"
	EventReviewerStarted            = EventReviewerSpawned
	EventReviewerCompleted          = "cerberus.reviewer.completed"
	EventReviewerFailed             = "cerberus.reviewer.failed"
	EventReviewRoundComplete        = "cerberus.review.round_complete"
	EventDebateRoundStarted         = "cerberus.debate.round_started"
	EventDebateRoundCompleted       = "cerberus.debate.round_completed"
	EventDebatePeerBroadcastWritten = "cerberus.debate.peer_broadcast_written"
	EventReviewResolved             = "cerberus.review.resolved"
	EventHookBlocked                = "cerberus.hook.blocked"
	EventHookAllowed                = "cerberus.hook.allowed"
)

type Event struct {
	Event     string         `json:"event"`
	Timestamp time.Time      `json:"timestamp"`
	Payload   map[string]any `json:"payload,omitempty"`
}

func (event Event) MarshalJSON() ([]byte, error) {
	record := make(map[string]any, len(event.Payload)+2)
	for key, value := range event.Payload {
		if key == "event" || key == "timestamp" {
			continue
		}
		record[key] = value
	}
	record["event"] = event.Event
	record["timestamp"] = event.Timestamp
	return json.Marshal(record)
}

func WriteEvent(runRoot string, event Event) error {
	path := filepath.Join(runRoot, "event-log.jsonl")
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("create event log directory: %w", err)
	}

	data, err := json.Marshal(event)
	if err != nil {
		return fmt.Errorf("marshal event: %w", err)
	}
	data = append(data, '\n')

	file, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return fmt.Errorf("open event log: %w", err)
	}
	defer file.Close()

	if _, err := file.Write(data); err != nil {
		return fmt.Errorf("append event log: %w", err)
	}
	return nil
}
