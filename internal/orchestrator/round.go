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
	System  []byte
	User    []byte
	Root    string
	RunRoot string
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

			system, err := systemPromptForSlot(slot, prompts)
			if err != nil {
				errs <- roundError{err: err}
				cancel()
				return
			}
			response, err := spawner.Spawn(ctx, reviewer.Request{
				ID:        slot.ID,
				Provider:  slot.Provider,
				Model:     slot.Model,
				System:    system,
				User:      prompts.User,
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

func systemPromptForSlot(slot ReviewerSlot, round roundPrompts) ([]byte, error) {
	if slot.Strategy == "" && slot.PersonaPath == "" {
		return round.System, nil
	}
	root := round.Root
	if root == "" {
		root = "."
	}
	system, _, err := prompts.ComposeFromRoot(root, roster.RosterSlot{
		Provider:    slot.Provider,
		Model:       slot.Model,
		Strategy:    slot.Strategy,
		PersonaPath: slot.PersonaPath,
	}, "code")
	if err != nil {
		return nil, err
	}
	if len(round.System) == 0 {
		return system, nil
	}
	if len(system) == 0 {
		return round.System, nil
	}
	return bytes.Join([][]byte{round.System, system}, []byte("\n\n")), nil
}

type roundError struct {
	err error
}
