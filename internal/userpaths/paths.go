// Package userpaths defines user-owned state locations. The installer's
// --config option relocates executable code, not these directories.
// Resolution has no filesystem side effects and preserves the legacy layout.
package userpaths

import "path/filepath"

type Layout struct {
	Config string
	Cache  string
	Logs   string
}

func ForHome(home string) Layout {
	return Layout{
		Config: filepath.Join(home, ".config", "mole"),
		Cache:  filepath.Join(home, ".cache", "mole"),
		Logs:   filepath.Join(home, "Library", "Logs", "mole"),
	}
}
