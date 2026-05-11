//go:build !windows

package cli

import (
	"os/exec"
	"syscall"
)

func configureDetachedRuntime(cmd *exec.Cmd) error {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	return nil
}
