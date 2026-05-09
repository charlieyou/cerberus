package generate

import (
	"bufio"
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
	if len(trimmed) == 0 {
		return nil, Stats{}, nil
	}
	if !json.Valid(trimmed) {
		return parseProviderJSONLines(provider, trimmed)
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

func parseProviderJSONLines(provider string, stdout []byte) ([]byte, Stats, error) {
	scanner := bufio.NewScanner(bytes.NewReader(stdout))
	scanner.Buffer(make([]byte, 0, 64*1024), 10*1024*1024)
	stats := Stats{}
	parsed := false
	for scanner.Scan() {
		line := bytes.TrimSpace(scanner.Bytes())
		if len(line) == 0 {
			continue
		}
		var payload providerJSONPayload
		if err := json.Unmarshal(line, &payload); err != nil {
			return nil, Stats{}, nil
		}
		parsed = true
		stats.add(payload.stats(provider))
	}
	if err := scanner.Err(); err != nil {
		return nil, Stats{}, err
	}
	if !parsed {
		return nil, Stats{}, nil
	}
	return append([]byte(nil), stdout...), stats, nil
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

func (payload providerJSONPayload) stats(provider string) Stats {
	stats := Stats{}
	tokens := payload.tokenStats(provider)
	if tokens.Input > 0 || tokens.Output > 0 {
		stats.Tokens = &tokens
	}
	if costUSD, ok := payload.costUSD(); ok {
		stats.CostUSD = &costUSD
	}
	return stats
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

func (stats *Stats) add(next Stats) {
	if next.Tokens != nil {
		if stats.Tokens == nil {
			stats.Tokens = &TokenStats{}
		}
		stats.Tokens.Input += next.Tokens.Input
		stats.Tokens.Output += next.Tokens.Output
	}
	if next.CostUSD != nil {
		if stats.CostUSD == nil {
			cost := 0.0
			stats.CostUSD = &cost
		}
		*stats.CostUSD += *next.CostUSD
	}
}
