package generate

import (
	"bytes"
	"encoding/json"
	"time"
)

type TokenStats struct {
	Input  int `json:"input"`
	Output int `json:"output"`
}

type Stats struct {
	Tokens         *TokenStats `json:"tokens,omitempty"`
	CostUSD        *float64    `json:"cost_usd,omitempty"`
	TimeToFinishMs int64       `json:"time_to_finish_ms"`
	ExitCode       int         `json:"exit_code"`
	ErrorMessage   string      `json:"error_message,omitempty"`
	StartedAt      time.Time   `json:"started_at"`
	EndedAt        time.Time   `json:"ended_at"`
}

func ParseProviderJSON(provider string, stdout []byte) ([]byte, Stats, error) {
	trimmed := bytes.TrimSpace(stdout)
	if len(trimmed) == 0 || !json.Valid(trimmed) {
		return nil, Stats{}, nil
	}

	var payload providerJSONPayload
	if err := json.Unmarshal(trimmed, &payload); err != nil {
		return nil, Stats{}, err
	}

	stats := Stats{}
	tokens := payload.tokenStats(provider)
	if tokens.Input > 0 || tokens.Output > 0 {
		stats.Tokens = &tokens
	}
	if costUSD, ok := payload.costUSD(); ok {
		stats.CostUSD = &costUSD
	}
	return append([]byte(nil), trimmed...), stats, nil
}

type providerJSONPayload struct {
	Tokens tokenPayload `json:"tokens"`
	Usage  struct {
		InputTokens      int `json:"input_tokens"`
		PromptTokens     int `json:"prompt_tokens"`
		OutputTokens     int `json:"output_tokens"`
		CompletionTokens int `json:"completion_tokens"`
	} `json:"usage"`
	CostUSD      *float64 `json:"cost_usd"`
	Cost         *float64 `json:"cost"`
	TotalCostUSD *float64 `json:"total_cost_usd"`
	Stats        struct {
		Cost   *float64                `json:"cost"`
		Models map[string]modelPayload `json:"models"`
	} `json:"stats"`
}

type tokenPayload struct {
	Input      int `json:"input"`
	Output     int `json:"output"`
	Candidates int `json:"candidates"`
}

type modelPayload struct {
	Tokens tokenPayload `json:"tokens"`
}

func (payload providerJSONPayload) tokenStats(provider string) TokenStats {
	tokens := TokenStats{
		Input:  firstPositive(payload.Tokens.Input, payload.Usage.InputTokens, payload.Usage.PromptTokens),
		Output: firstPositive(payload.Tokens.Output, payload.Tokens.Candidates, payload.Usage.OutputTokens, payload.Usage.CompletionTokens),
	}
	if tokens.Input > 0 || tokens.Output > 0 {
		return tokens
	}
	if provider == "gemini" {
		for _, model := range payload.Stats.Models {
			tokens.Input += model.Tokens.Input
			tokens.Output += firstPositive(model.Tokens.Output, model.Tokens.Candidates)
		}
	}
	return tokens
}

func (payload providerJSONPayload) costUSD() (float64, bool) {
	for _, value := range []*float64{payload.CostUSD, payload.TotalCostUSD, payload.Cost, payload.Stats.Cost} {
		if value != nil {
			return *value, true
		}
	}
	return 0, false
}

func firstPositive(values ...int) int {
	for _, value := range values {
		if value > 0 {
			return value
		}
	}
	return 0
}
