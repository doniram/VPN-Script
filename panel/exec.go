package main

import (
	"context"
	"os"
	"os/exec"
	"strings"
	"time"
)

// cliPath is the scriptvps CLI. Overridable for testing.
func cliPath() string {
	if p := os.Getenv("SVPS_PANEL_CLI"); p != "" {
		return p
	}
	return "/usr/local/bin/scriptvps"
}

// runCLI executes `scriptvps <args...>` without a shell.
// When the panel runs as root it calls the CLI directly; otherwise it uses
// `sudo -n`. Argument vectors are built by the caller (no shell interpolation).
func runCLI(args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()

	var cmd *exec.Cmd
	if os.Geteuid() == 0 {
		cmd = exec.CommandContext(ctx, cliPath(), args...)
	} else {
		full := append([]string{"-n", cliPath()}, args...)
		cmd = exec.CommandContext(ctx, "sudo", full...)
	}
	out, err := cmd.CombinedOutput()
	return strings.TrimSpace(string(out)), err
}
