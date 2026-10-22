//go:build darwin

package main

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"testing"
)

func TestTrashFallbackBindsOriginalTarget(t *testing.T) {
	for _, change := range []string{"target", "parent", "symlink"} {
		t.Run(change, func(t *testing.T) {
			root := t.TempDir()
			parent := filepath.Join(root, "parent")
			if err := os.Mkdir(parent, 0o700); err != nil {
				t.Fatal(err)
			}
			path := filepath.Join(parent, "item")
			if err := os.WriteFile(path, []byte("original"), 0o600); err != nil {
				t.Fatal(err)
			}
			firstCalled, fallbackCalled := false, false
			first := func(string) error {
				firstCalled = true
				switch change {
				case "target":
					if err := os.Rename(path, path+".old"); err != nil {
						t.Fatal(err)
					}
				case "parent", "symlink":
					if err := os.Rename(parent, parent+".old"); err != nil {
						t.Fatal(err)
					}
					if change == "symlink" {
						if err := os.Symlink(parent+".old", parent); err != nil {
							t.Fatal(err)
						}
					} else if err := os.Mkdir(parent, 0o700); err != nil {
						t.Fatal(err)
					}
				}
				if change != "symlink" {
					if err := os.WriteFile(path, []byte("replacement"), 0o600); err != nil {
						t.Fatal(err)
					}
				}
				return errors.New("transport failed")
			}
			err := moveToTrashWithRoutes(path, first, func(string) error {
				fallbackCalled = true
				return nil
			})
			if !firstCalled || fallbackCalled || err == nil {
				t.Fatalf("identity change must stop fallback: first=%v fallback=%v err=%v", firstCalled, fallbackCalled, err)
			}
			if _, err := os.Lstat(path); err != nil {
				t.Fatalf("retained target: %v", err)
			}
		})
	}
}

func TestTrashBatchCancellationKeepsCompletedLedger(t *testing.T) {
	for _, stop := range []error{context.Canceled, context.DeadlineExceeded} {
		t.Run(stop.Error(), func(t *testing.T) {
			paths := []string{"/fixture/first", "/fixture/second", "/fixture/third"}
			var calls []string
			move := func(path string, _ *int64) (int64, error) {
				calls = append(calls, path)
				if path == paths[1] {
					return 0, stop
				}
				return 1, nil
			}
			result := deleteMultiplePathsUsing(paths, nil, nil, move)().(deleteProgressMsg)
			if result.err == nil || result.count != 1 || !slices.Equal(result.removedPaths, paths[:1]) || !slices.Equal(calls, paths[:2]) {
				t.Fatalf("batch lost completed ledger or continued after cancellation: result=%+v calls=%v", result, calls)
			}
			// Positive control: the third path is otherwise eligible.
			calls = nil
			result = deleteMultiplePathsUsing(paths[2:], nil, nil, move)().(deleteProgressMsg)
			if result.err != nil || result.count != 1 || !slices.Equal(calls, paths[2:]) {
				t.Fatalf("later path not eligible in the control: %+v %v", result, calls)
			}
		})
	}
}

func TestTrashFallbackStopsAfterCancellation(t *testing.T) {
	for _, stop := range []error{context.Canceled, context.DeadlineExceeded} {
		t.Run(stop.Error(), func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "item")
			if err := os.WriteFile(path, nil, 0o600); err != nil {
				t.Fatal(err)
			}
			fallbackCalled := false
			err := moveToTrashWithRoutes(path, func(string) error { return stop }, func(string) error {
				fallbackCalled = true
				return nil
			})
			if fallbackCalled || !errors.Is(err, stop) {
				t.Fatalf("cancellation must stop fallback: called=%v err=%v", fallbackCalled, err)
			}
		})
	}
}

func TestTrashFallbackContinuesForUnchangedTarget(t *testing.T) {
	path := filepath.Join(t.TempDir(), "item")
	if err := os.WriteFile(path, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	calls := 0
	err := moveToTrashWithRoutes(path, func(string) error {
		calls++
		return errors.New("unavailable")
	}, func(string) error {
		calls++
		return nil
	})
	if err != nil || calls != 2 {
		t.Fatalf("unchanged target should reach fallback: calls=%d err=%v", calls, err)
	}
}
