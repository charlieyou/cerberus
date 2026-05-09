package orchestrator

import (
	"context"
	"fmt"
	"sync"

	"github.com/charlieyou/cerberus/internal/reviewer"
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
	errs := make(chan error, len(slots))
	var wg sync.WaitGroup

	for i, slot := range slots {
		i, slot := i, slot
		wg.Add(1)
		go func() {
			defer wg.Done()

			response, err := spawner.Spawn(ctx, reviewer.Request{
				ID:        slot.ID,
				Provider:  slot.Provider,
				Model:     slot.Model,
				System:    prompts.System,
				User:      prompts.User,
				Root:      prompts.Root,
				RunRoot:   prompts.RunRoot,
				Iteration: 1,
				Round:     1,
			})
			if err != nil {
				cancel()
				errs <- err
				return
			}
			parsed := response.Parsed
			if parsed == nil {
				parsed, err = reviewer.Parse(response.Output)
				if err != nil {
					cancel()
					errs <- err
					return
				}
			}
			outputs[i] = *parsed
		}()
	}

	wg.Wait()
	close(errs)
	for err := range errs {
		if err != nil {
			return nil, err
		}
	}
	return outputs, nil
}
