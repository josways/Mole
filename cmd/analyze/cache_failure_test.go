//go:build darwin

package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestCacheSaveRetainsDestinationOnRenameFailure(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	root := filepath.Join(home, "root")
	if err := os.Mkdir(root, 0o700); err != nil {
		t.Fatal(err)
	}
	cachePath, err := getCachePath(root)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(cachePath, 0o700); err != nil {
		t.Fatal(err)
	}
	marker := filepath.Join(cachePath, "keep")
	if err := os.WriteFile(marker, []byte("retained"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := saveCacheToDisk(root, scanResult{TotalSize: 42, TotalFiles: 1}); err == nil {
		t.Fatal("rename failure reported success")
	}
	if data, err := os.ReadFile(marker); err != nil || string(data) != "retained" {
		t.Fatalf("failed save changed existing destination: %q %v", data, err)
	}
	staged, err := filepath.Glob(filepath.Join(filepath.Dir(cachePath), "*.tmp"))
	if err != nil || len(staged) != 0 {
		t.Fatalf("failed save leaked staging files: %v %v", staged, err)
	}
}

func TestCacheMeasurementsArePrivate(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	resetOverviewSnapshotForTest()
	root := filepath.Join(home, "root")
	if err := os.Mkdir(root, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := saveCacheToDisk(root, scanResult{TotalSize: 42, TotalFiles: 1}); err != nil {
		t.Fatal(err)
	}
	if err := storeOverviewSize(root, 42); err != nil {
		t.Fatal(err)
	}
	cachePath, err := getCachePath(root)
	if err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{cachePath, filepath.Join(filepath.Dir(cachePath), overviewCacheFile)} {
		info, err := os.Stat(path)
		if err != nil || info.Mode().Perm() != 0o600 {
			t.Fatalf("measurement file is not private: %s %v", path, err)
		}
	}
}
