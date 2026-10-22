//go:build darwin

package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestSharedDeletionContract(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("MOLE_TEST_NO_AUTH", "1")
	if err := os.Symlink("/System", filepath.Join(home, "critical-link")); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile("../../tests/contracts/deletion.tsv")
	if err != nil {
		t.Fatal(err)
	}
	accepted, rejected := 0, 0
	for line := range strings.SplitSeq(string(data), "\n") {
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		verdict, path, ok := strings.Cut(line, "\t")
		if !ok || (verdict != "accept" && verdict != "reject") {
			t.Fatalf("invalid shared contract row: %q", line)
		}
		path = strings.ReplaceAll(path, "{HOME}", home)
		t.Run(path, func(t *testing.T) {
			want := verdict == "accept"
			if got := validateTrashTarget(path) == nil; got != want {
				t.Errorf("Analyze accepted=%v, want %v", got, want)
			}
			cmd := exec.Command("/bin/bash", "--noprofile", "--norc", "-c", `
set -euo pipefail
source lib/core/common.sh
if validate_path_for_deletion "$1" >/dev/null 2>&1; then printf accept; else printf reject; fi
`, "contract", path)
			cmd.Dir = "../.."
			out, err := cmd.Output()
			if err != nil {
				t.Fatalf("Shell contract did not execute: %v", err)
			}
			if string(out) != verdict {
				t.Errorf("Shell verdict=%q, want %q", out, verdict)
			}
		})
		if verdict == "accept" {
			accepted++
		} else {
			rejected++
		}
	}
	if accepted == 0 || rejected == 0 {
		t.Fatalf("contract needs positive and negative controls: accept=%d reject=%d", accepted, rejected)
	}
}

func TestSharedLogEscapingContract(t *testing.T) {
	// Shell variables cannot hold NUL. Every other byte, including invalid
	// UTF-8 and literal backslashes, must obey the same byte-wise contract.
	var input strings.Builder
	for value := 1; value <= 255; value++ {
		input.WriteByte(byte(value))
	}
	input.WriteString(`literal\n\t`)
	cmd := exec.Command("/bin/bash", "--noprofile", "--norc", "-c", `
set -euo pipefail
source lib/core/base.sh
escaped=""
_mole_escape_log_value escaped "$1"
printf '%s' "$escaped"
`, "contract", input.String())
	cmd.Dir = "../.."
	cmd.Env = append(os.Environ(), "LC_ALL=C", "MOLE_TEST_NO_AUTH=1")
	output, err := cmd.Output()
	if err != nil {
		t.Fatal(err)
	}
	if want := escapeLogValue(input.String()); string(output) != want {
		t.Fatalf("Shell/Go escape mismatch:\nShell %q\nGo    %q", output, want)
	}
	for _, value := range output {
		if value < 0x20 || value == 0x7f {
			t.Fatalf("raw control byte in shared log: %#x", value)
		}
	}
}
