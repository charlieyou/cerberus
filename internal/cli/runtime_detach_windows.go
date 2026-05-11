//go:build windows

package cli

import (
	"fmt"
	"os/exec"
)

func configureDetachedRuntime(cmd *exec.Cmd) error {
	return fmt.Errorf("detached Cerberus runtime launch is not supported on Windows")
}
