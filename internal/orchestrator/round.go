package orchestrator

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"sync"

	"github.com/charlieyou/cerberus/internal/prompts"
	"github.com/charlieyou/cerberus/internal/reviewer"
	"github.com/charlieyou/cerberus/internal/roster"
)

type roundPrompts struct {
	System      []byte
	User        []byte
	Root        string
	RunRoot     string
	RuntimeMode string
}

func runRound(ctx context.Context, slots []ReviewerSlot, spawner reviewer.Spawner, prompts roundPrompts) ([]reviewer.RawReviewerOutput, error) {
	if len(slots) == 0 {
		return nil, fmt.Errorf("review round requires at least one reviewer")
	}
	if spawner == nil {
		return nil, fmt.Errorf("reviewer spawner is nil")
	}

	ctx, cancel := context.WithCancel(ctx)
	defer cancel()

	outputs := make([]reviewer.RawReviewerOutput, len(slots))
	errs := make(chan roundError, len(slots))
	var wg sync.WaitGroup

	for i, slot := range slots {
		i, slot := i, slot
		wg.Add(1)
		go func() {
			defer wg.Done()

			system, user, err := promptsForSlot(slot, prompts)
			if err != nil {
				errs <- roundError{err: err}
				cancel()
				return
			}
			response, err := spawner.Spawn(ctx, reviewer.Request{
				ID:        slot.ID,
				Provider:  slot.Provider,
				Model:     slot.Model,
				Mode:      firstNonEmpty(slot.Mode, prompts.RuntimeMode),
				System:    system,
				User:      user,
				Root:      prompts.Root,
				RunRoot:   prompts.RunRoot,
				Iteration: 1,
				Round:     1,
			})
			if err != nil {
				errs <- roundError{err: err}
				cancel()
				return
			}
			parsed := response.Parsed
			if parsed == nil {
				parsed, err = reviewer.Parse(response.Output)
				if err != nil {
					errs <- roundError{err: err}
					cancel()
					return
				}
			}
			outputs[i] = *parsed
		}()
	}

	wg.Wait()
	close(errs)
	var canceled error
	for result := range errs {
		if result.err == nil {
			continue
		}
		if errors.Is(result.err, context.Canceled) {
			if canceled == nil {
				canceled = result.err
			}
			continue
		}
		return nil, result.err
	}
	if canceled != nil {
		return nil, canceled
	}
	return outputs, nil
}

func promptsForSlot(slot ReviewerSlot, round roundPrompts) ([]byte, []byte, error) {
	root := round.Root
	if root == "" {
		root = "."
	}
	system, user, err := prompts.ComposeFromRoot(root, roster.RosterSlot{
		Provider:    slot.Provider,
		Model:       slot.Model,
		Strategy:    slot.Strategy,
		PersonaPath: slot.PersonaPath,
		Mode:        slot.Mode,
	}, "code")
	if err != nil {
		return nil, nil, err
	}
	user = appendPrompt(user, round.User)
	if len(round.System) == 0 {
		return system, user, nil
	}
	if len(system) == 0 {
		return round.System, user, nil
	}
	return bytes.Join([][]byte{round.System, system}, []byte("\n\n")), user, nil
}

func appendPrompt(base, extra []byte) []byte {
	if len(base) == 0 {
		return extra
	}
	if len(extra) == 0 {
		return base
	}
	return bytes.Join([][]byte{base, extra}, []byte("\n\n"))
}

type roundError struct {
	err error
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value != "" {
			return value
		}
	}
	return ""
}
