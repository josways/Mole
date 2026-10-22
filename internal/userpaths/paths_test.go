package userpaths

import (
	"os/exec"
	"strings"
	"testing"
)

func TestLegacyLayoutMatchesShell(t *testing.T) {
	for _, home := range []string{"/Users/example", "/Users/with spaces", "/Users/中文", "/Users/literal$(`value`)"} {
		t.Run(home, func(t *testing.T) {
			layout := ForHome(home)
			want := strings.Join([]string{home + "/.config/mole", home + "/.cache/mole", home + "/Library/Logs/mole"}, "\n")
			if got := strings.Join([]string{layout.Config, layout.Cache, layout.Logs}, "\n"); got != want {
				t.Fatalf("Go layout=%q, want %q", got, want)
			}
			cmd := exec.Command("/bin/bash", "--noprofile", "--norc", "-c", `
set -euo pipefail
source ../../lib/core/paths.sh
for kind in config cache logs; do
    mole_user_path_into resolved "$kind" "$1"
    printf '%s\n' "$resolved"
done
`, "contract", home)
			out, err := cmd.Output()
			if err != nil {
				t.Fatalf("Shell path resolver: %v", err)
			}
			if strings.TrimSuffix(string(out), "\n") != want {
				t.Fatalf("Shell layout=%q, want %q", out, want)
			}
		})
	}
}
