//go:build darwin

package main

import (
	"context"
	"encoding/gob"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"syscall"
	"testing"
	"time"
)

func TestCacheSaveLoadRoundTrip(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	target := filepath.Join(home, "cache-target")
	if err := os.MkdirAll(target, 0o755); err != nil {
		t.Fatalf("create target dir: %v", err)
	}

	result := scanResult{
		Entries: []dirEntry{
			{Name: "alpha", Path: filepath.Join(target, "alpha"), Size: 10, IsDir: true},
		},
		LargeFiles: []fileEntry{
			{Name: "big.bin", Path: filepath.Join(target, "big.bin"), Size: 2048},
		},
		TotalSize: 42,
	}

	if err := saveCacheToDisk(target, result); err != nil {
		t.Fatalf("saveCacheToDisk: %v", err)
	}

	cache, err := loadCacheFromDisk(target)
	if err != nil {
		t.Fatalf("loadCacheFromDisk: %v", err)
	}
	if cache.TotalSize != result.TotalSize {
		t.Fatalf("total size mismatch: want %d, got %d", result.TotalSize, cache.TotalSize)
	}
	if len(cache.Entries) != len(result.Entries) {
		t.Fatalf("entry count mismatch: want %d, got %d", len(result.Entries), len(cache.Entries))
	}
	if len(cache.LargeFiles) != len(result.LargeFiles) {
		t.Fatalf("large file count mismatch: want %d, got %d", len(result.LargeFiles), len(cache.LargeFiles))
	}
}

func TestPruneAnalyzerCacheDirRemovesOnlyExpiredCacheFiles(t *testing.T) {
	cacheDir := t.TempDir()
	now := time.Now()
	oldTime := now.Add(-analyzerCacheTTL - time.Hour)
	freshTime := now.Add(-time.Hour)

	oldCache := filepath.Join(cacheDir, "old.cache")
	freshCache := filepath.Join(cacheDir, "fresh.cache")
	namedState := filepath.Join(cacheDir, overviewCacheFile)
	cacheDirEntry := filepath.Join(cacheDir, "directory.cache")
	symlinkTarget := filepath.Join(cacheDir, "target")
	symlinkCache := filepath.Join(cacheDir, "link.cache")

	for _, path := range []string{oldCache, freshCache, namedState, symlinkTarget} {
		if err := os.WriteFile(path, []byte("cache"), 0o644); err != nil {
			t.Fatalf("write %s: %v", path, err)
		}
	}
	if err := os.Mkdir(cacheDirEntry, 0o755); err != nil {
		t.Fatalf("mkdir cache dir entry: %v", err)
	}
	if err := os.Symlink(symlinkTarget, symlinkCache); err != nil {
		t.Fatalf("symlink cache entry: %v", err)
	}

	for _, path := range []string{oldCache, namedState, cacheDirEntry, symlinkCache} {
		if err := os.Chtimes(path, oldTime, oldTime); err != nil {
			t.Fatalf("chtimes %s: %v", path, err)
		}
	}
	if err := os.Chtimes(freshCache, freshTime, freshTime); err != nil {
		t.Fatalf("chtimes fresh cache: %v", err)
	}

	if err := pruneAnalyzerCacheDir(cacheDir, now); err != nil {
		t.Fatalf("pruneAnalyzerCacheDir: %v", err)
	}

	if _, err := os.Stat(oldCache); !os.IsNotExist(err) {
		t.Fatalf("expected expired cache file to be removed, stat err: %v", err)
	}
	for _, path := range []string{freshCache, namedState, cacheDirEntry, symlinkCache} {
		if _, err := os.Lstat(path); err != nil {
			t.Fatalf("expected %s to be preserved: %v", path, err)
		}
	}
}

func TestPruneAnalyzerCacheDirMissingDirectory(t *testing.T) {
	missing := filepath.Join(t.TempDir(), "missing")
	if err := pruneAnalyzerCacheDir(missing, time.Now()); err != nil {
		t.Fatalf("expected missing cache dir to be ignored, got: %v", err)
	}
}

func TestPruneAnalyzerCacheDirIgnoresRemoveFailures(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root can remove files from read-only directories")
	}

	cacheDir := t.TempDir()
	oldCache := filepath.Join(cacheDir, "old.cache")
	if err := os.WriteFile(oldCache, []byte("cache"), 0o644); err != nil {
		t.Fatalf("write old cache: %v", err)
	}
	oldTime := time.Now().Add(-analyzerCacheTTL - time.Hour)
	if err := os.Chtimes(oldCache, oldTime, oldTime); err != nil {
		t.Fatalf("chtimes old cache: %v", err)
	}

	if err := os.Chmod(cacheDir, 0o555); err != nil {
		t.Fatalf("chmod cache dir read-only: %v", err)
	}
	defer func() {
		_ = os.Chmod(cacheDir, 0o755)
	}()

	if err := pruneAnalyzerCacheDir(cacheDir, time.Now()); err != nil {
		t.Fatalf("expected remove failure to be ignored, got: %v", err)
	}
	if _, err := os.Stat(oldCache); err != nil {
		t.Fatalf("expected failed removal to leave cache file in place: %v", err)
	}
}

// writeAgedCacheFiles lays down n fresh cache files, oldest first, one minute
// apart so eviction order is unambiguous.
func writeAgedCacheFiles(t *testing.T, cacheDir string, n int, payload int) []string {
	t.Helper()
	base := time.Now().Add(-time.Duration(n) * time.Minute)
	names := make([]string, 0, n)
	for i := range n {
		name := filepath.Join(cacheDir, fmt.Sprintf("entry-%03d.cache", i))
		if err := os.WriteFile(name, []byte(strings.Repeat("x", payload)), 0o644); err != nil {
			t.Fatalf("write %s: %v", name, err)
		}
		stamp := base.Add(time.Duration(i) * time.Minute)
		if err := os.Chtimes(name, stamp, stamp); err != nil {
			t.Fatalf("chtimes %s: %v", name, err)
		}
		names = append(names, name)
	}
	return names
}

// A TTL alone cannot bound a store whose entries are all refreshed inside it;
// the count cap is what keeps the newest N and drops the rest, oldest first.
func TestPruneAnalyzerCacheDirEnforcesEntryCap(t *testing.T) {
	cacheDir := t.TempDir()
	names := writeAgedCacheFiles(t, cacheDir, 10, 16)

	if err := pruneAnalyzerCacheDirWithLimits(cacheDir, time.Now(), 4, 0); err != nil {
		t.Fatalf("pruneAnalyzerCacheDirWithLimits: %v", err)
	}

	for i, name := range names {
		_, err := os.Stat(name)
		if i < 6 && !os.IsNotExist(err) {
			t.Fatalf("expected oldest entry %s to be evicted, stat err: %v", name, err)
		}
		if i >= 6 && err != nil {
			t.Fatalf("expected newest entry %s to be retained: %v", name, err)
		}
	}
}

func TestPruneAnalyzerCacheDirEnforcesByteCap(t *testing.T) {
	cacheDir := t.TempDir()
	names := writeAgedCacheFiles(t, cacheDir, 10, 100)

	// The count cap is set out of the way so only the byte cap can evict:
	// room for exactly three of the 100-byte entries.
	if err := pruneAnalyzerCacheDirWithLimits(cacheDir, time.Now(), len(names), 300); err != nil {
		t.Fatalf("pruneAnalyzerCacheDirWithLimits: %v", err)
	}

	for i, name := range names {
		_, err := os.Stat(name)
		if i < 7 && !os.IsNotExist(err) {
			t.Fatalf("expected oldest entry %s to be evicted, stat err: %v", name, err)
		}
		if i >= 7 && err != nil {
			t.Fatalf("expected newest entry %s to be retained: %v", name, err)
		}
	}
}

// The legacy flat store shares `~/.cache/mole` with shell-side state, so the
// sweep is scoped to the two names the analyzer ever wrote there.
func TestSweepLegacyAnalyzerCacheRemovesOnlyAnalyzerFiles(t *testing.T) {
	root := t.TempDir()

	legacyEntry := filepath.Join(root, "deadbeef.cache")
	legacyOverview := filepath.Join(root, overviewCacheFile)
	shellState := filepath.Join(root, "installed_apps_cache")
	permissionFlag := filepath.Join(root, "permissions_granted")
	for _, path := range []string{legacyEntry, legacyOverview, shellState, permissionFlag} {
		if err := os.WriteFile(path, []byte("state"), 0o644); err != nil {
			t.Fatalf("write %s: %v", path, err)
		}
	}
	analyzerDir := filepath.Join(root, analyzerCacheDirName)
	if err := os.Mkdir(analyzerDir, 0o755); err != nil {
		t.Fatalf("mkdir analyzer dir: %v", err)
	}
	currentEntry := filepath.Join(analyzerDir, "deadbeef.cache")
	if err := os.WriteFile(currentEntry, []byte("current"), 0o644); err != nil {
		t.Fatalf("write current entry: %v", err)
	}

	if err := sweepLegacyAnalyzerCache(root); err != nil {
		t.Fatalf("sweepLegacyAnalyzerCache: %v", err)
	}

	for _, path := range []string{legacyEntry, legacyOverview} {
		if _, err := os.Stat(path); !os.IsNotExist(err) {
			t.Fatalf("expected legacy file %s to be swept, stat err: %v", path, err)
		}
	}
	for _, path := range []string{shellState, permissionFlag, currentEntry, analyzerDir} {
		if _, err := os.Lstat(path); err != nil {
			t.Fatalf("expected %s to be preserved: %v", path, err)
		}
	}
}

func TestSweepLegacyAnalyzerCacheMissingRoot(t *testing.T) {
	missing := filepath.Join(t.TempDir(), "missing")
	if err := sweepLegacyAnalyzerCache(missing); err != nil {
		t.Fatalf("expected missing root to be ignored, got: %v", err)
	}
}

// Rejecting an expired entry without deleting it leaves the file on disk for a
// whole TTL, waiting on a prune pass that may never reach it.
func TestLoadCacheFromDiskRemovesExpiredEntry(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	target := filepath.Join(home, "target")
	if err := os.MkdirAll(target, 0o755); err != nil {
		t.Fatalf("create target: %v", err)
	}
	if err := saveCacheToDisk(target, scanResult{TotalSize: 1024, TotalFiles: 4}); err != nil {
		t.Fatalf("saveCacheToDisk: %v", err)
	}
	cachePath, err := getCachePath(target)
	if err != nil {
		t.Fatalf("getCachePath: %v", err)
	}

	expired := time.Now().Add(-analyzerCacheTTL - time.Hour)
	if err := os.Chtimes(cachePath, expired, expired); err != nil {
		t.Fatalf("chtimes cache: %v", err)
	}
	// ScanTime lives inside the payload, so age it there too.
	entry, err := loadRawCacheFromDisk(target)
	if err != nil {
		t.Fatalf("loadRawCacheFromDisk: %v", err)
	}
	entry.ScanTime = expired
	file, err := os.Create(cachePath)
	if err != nil {
		t.Fatalf("rewrite cache: %v", err)
	}
	if err := gob.NewEncoder(file).Encode(*entry); err != nil {
		file.Close() //nolint:errcheck
		t.Fatalf("encode cache: %v", err)
	}
	file.Close() //nolint:errcheck

	if _, err := loadCacheFromDisk(target); err == nil {
		t.Fatalf("expected expired cache to be rejected")
	}
	if _, err := os.Stat(cachePath); !os.IsNotExist(err) {
		t.Fatalf("expected expired cache file to be deleted, stat err: %v", err)
	}
}

func TestLoadCacheFromDiskRemovesEntryForMissingDirectory(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	target := filepath.Join(home, "target")
	if err := os.MkdirAll(target, 0o755); err != nil {
		t.Fatalf("create target: %v", err)
	}
	if err := saveCacheToDisk(target, scanResult{TotalSize: 1024, TotalFiles: 4}); err != nil {
		t.Fatalf("saveCacheToDisk: %v", err)
	}
	cachePath, err := getCachePath(target)
	if err != nil {
		t.Fatalf("getCachePath: %v", err)
	}
	if err := os.RemoveAll(target); err != nil {
		t.Fatalf("remove target: %v", err)
	}

	if _, err := loadCacheFromDisk(target); err == nil {
		t.Fatalf("expected missing directory to fail the load")
	}
	if _, err := os.Stat(cachePath); !os.IsNotExist(err) {
		t.Fatalf("expected orphaned cache file to be deleted, stat err: %v", err)
	}
}

func TestLoadRawCacheFromDiskRemovesUndecodableEntry(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	target := filepath.Join(home, "target")
	if err := os.MkdirAll(target, 0o755); err != nil {
		t.Fatalf("create target: %v", err)
	}
	cachePath, err := getCachePath(target)
	if err != nil {
		t.Fatalf("getCachePath: %v", err)
	}
	if err := os.WriteFile(cachePath, []byte("not gob"), 0o644); err != nil {
		t.Fatalf("write corrupt cache: %v", err)
	}

	if _, err := loadRawCacheFromDisk(target); err == nil {
		t.Fatalf("expected corrupt cache to fail decoding")
	}
	if _, err := os.Stat(cachePath); !os.IsNotExist(err) {
		t.Fatalf("expected corrupt cache file to be deleted, stat err: %v", err)
	}
}

// getCacheDir memoizes MkdirAll, so it has to notice when HOME moves or every
// test after the first would write into the first one's temp directory.
func TestGetCacheDirFollowsHomeChanges(t *testing.T) {
	firstHome := t.TempDir()
	t.Setenv("HOME", firstHome)
	first, err := getCacheDir()
	if err != nil {
		t.Fatalf("getCacheDir(first): %v", err)
	}
	if !strings.HasPrefix(first, firstHome) {
		t.Fatalf("cache dir %q not under HOME %q", first, firstHome)
	}

	secondHome := t.TempDir()
	t.Setenv("HOME", secondHome)
	second, err := getCacheDir()
	if err != nil {
		t.Fatalf("getCacheDir(second): %v", err)
	}
	if !strings.HasPrefix(second, secondHome) {
		t.Fatalf("cache dir %q not under new HOME %q", second, secondHome)
	}
	if first == second {
		t.Fatalf("expected cache dir to change with HOME, got %q twice", first)
	}
	if _, err := os.Stat(second); err != nil {
		t.Fatalf("expected new cache dir to be created: %v", err)
	}
}

// Every save rewrites the whole overview store, so re-measuring a directory to
// the size already on record must not touch the disk at all.
func TestStoreOverviewSizeSkipsWriteWhenValueUnchanged(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	resetOverviewSnapshotForTest()

	const target = "/Users/someone/project"
	if err := storeOverviewSize(target, 4096); err != nil {
		t.Fatalf("storeOverviewSize: %v", err)
	}
	storePath, err := getOverviewSizeStorePath()
	if err != nil {
		t.Fatalf("getOverviewSizeStorePath: %v", err)
	}
	if err := os.Remove(storePath); err != nil {
		t.Fatalf("remove store: %v", err)
	}

	if err := storeOverviewSize(target, 4096); err != nil {
		t.Fatalf("storeOverviewSize(repeat): %v", err)
	}
	if _, err := os.Stat(storePath); !os.IsNotExist(err) {
		t.Fatalf("expected repeat save of an unchanged size to skip the write, stat err: %v", err)
	}

	if err := storeOverviewSize(target, 8192); err != nil {
		t.Fatalf("storeOverviewSize(changed): %v", err)
	}
	if _, err := os.Stat(storePath); err != nil {
		t.Fatalf("expected a changed size to be persisted: %v", err)
	}
}

func TestEnsureOverviewSnapshotCacheDropsExpiredAndLegacyEntries(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	resetOverviewSnapshotForTest()

	storePath, err := getOverviewSizeStorePath()
	if err != nil {
		t.Fatalf("getOverviewSizeStorePath: %v", err)
	}
	seeded := map[string]overviewSizeSnapshot{
		"/fresh":   {Size: 1 << 20, Updated: time.Now().Add(-time.Hour), SchemaVersion: cacheSchemaVersion},
		"/expired": {Size: 1 << 20, Updated: time.Now().Add(-overviewCacheTTL - time.Hour), SchemaVersion: cacheSchemaVersion},
		"/empty":   {Size: 0, Updated: time.Now(), SchemaVersion: cacheSchemaVersion},
		"/legacy":  {Size: 1 << 20, Updated: time.Now()},
	}
	data, err := json.Marshal(seeded)
	if err != nil {
		t.Fatalf("marshal seed: %v", err)
	}
	if err := os.WriteFile(storePath, data, 0o644); err != nil {
		t.Fatalf("write seed: %v", err)
	}

	if _, err := loadStoredOverviewSize("/fresh"); err != nil {
		t.Fatalf("expected fresh snapshot to load: %v", err)
	}

	overviewSnapshotMu.Lock()
	_, hasExpired := overviewSnapshotCache["/expired"]
	_, hasEmpty := overviewSnapshotCache["/empty"]
	_, hasLegacy := overviewSnapshotCache["/legacy"]
	_, hasFresh := overviewSnapshotCache["/fresh"]
	overviewSnapshotMu.Unlock()

	if hasExpired || hasEmpty || hasLegacy {
		t.Fatalf("expected expired, empty, and legacy snapshots to be dropped on load")
	}
	if !hasFresh {
		t.Fatalf("expected fresh snapshot to survive load")
	}
}

func TestEvictOverviewSnapshotsKeepsNewest(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	resetOverviewSnapshotForTest()

	base := time.Now().Add(-time.Duration(overviewCacheMaxEntries+1) * time.Minute)
	overviewSnapshotMu.Lock()
	overviewSnapshotCache = make(map[string]overviewSizeSnapshot, overviewCacheMaxEntries+1)
	overviewSnapshotLoaded = true
	for i := range overviewCacheMaxEntries + 1 {
		overviewSnapshotCache[fmt.Sprintf("/dir-%04d", i)] = overviewSizeSnapshot{
			Size:          int64(i + 1),
			Updated:       base.Add(time.Duration(i) * time.Minute),
			SchemaVersion: cacheSchemaVersion,
		}
	}
	evictOverviewSnapshotsLocked()
	remaining := len(overviewSnapshotCache)
	_, oldestKept := overviewSnapshotCache["/dir-0000"]
	_, newestKept := overviewSnapshotCache[fmt.Sprintf("/dir-%04d", overviewCacheMaxEntries)]
	overviewSnapshotMu.Unlock()

	if remaining != overviewCacheKeepEntries {
		t.Fatalf("expected %d snapshots after eviction, got %d", overviewCacheKeepEntries, remaining)
	}
	if oldestKept {
		t.Fatalf("expected the oldest snapshot to be evicted")
	}
	if !newestKept {
		t.Fatalf("expected the newest snapshot to be kept")
	}
}

// Dropping snapshots one child at a time rewrote the whole overview store per
// child; the tree invalidation has to land as a single save.
func TestInvalidateCacheTreeDropsChildSnapshotsInOneSave(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	resetOverviewSnapshotForTest()

	parent := filepath.Join(home, "parent")
	childA := filepath.Join(parent, "a")
	childB := filepath.Join(parent, "b")
	for _, dir := range []string{childA, childB} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatalf("mkdir %s: %v", dir, err)
		}
	}
	for _, dir := range []string{parent, childA, childB} {
		if err := storeOverviewSize(dir, 1<<20); err != nil {
			t.Fatalf("storeOverviewSize(%s): %v", dir, err)
		}
		if err := saveCacheToDisk(dir, scanResult{TotalSize: 1 << 20, TotalFiles: 3}); err != nil {
			t.Fatalf("saveCacheToDisk(%s): %v", dir, err)
		}
	}

	storePath, err := getOverviewSizeStorePath()
	if err != nil {
		t.Fatalf("getOverviewSizeStorePath: %v", err)
	}
	if err := os.Remove(storePath); err != nil {
		t.Fatalf("remove store: %v", err)
	}

	invalidateCacheTree(parent)

	// Exactly one save recreated the file, and it holds none of the tree.
	data, err := os.ReadFile(storePath)
	if err != nil {
		t.Fatalf("expected the invalidation to persist once: %v", err)
	}
	var persisted map[string]overviewSizeSnapshot
	if err := json.Unmarshal(data, &persisted); err != nil {
		t.Fatalf("unmarshal store: %v", err)
	}
	for _, dir := range []string{parent, childA, childB} {
		if _, ok := persisted[dir]; ok {
			t.Fatalf("expected %s snapshot to be dropped", dir)
		}
		cachePath, err := getCachePath(dir)
		if err != nil {
			t.Fatalf("getCachePath(%s): %v", dir, err)
		}
		if _, err := os.Stat(cachePath); !os.IsNotExist(err) {
			t.Fatalf("expected %s cache entry to be removed, stat err: %v", dir, err)
		}
	}
}

// Atomic saves stage through temp files, and prune is the only thing that ever
// looks in that directory: without this, a process killed mid-write leaks a
// temp file that nothing would ever collect.
func TestPruneAnalyzerCacheDirRemovesStaleTempFiles(t *testing.T) {
	cacheDir := t.TempDir()
	now := time.Now()

	staleTemp := filepath.Join(cacheDir, "entry-123.tmp")
	freshTemp := filepath.Join(cacheDir, "entry-456.tmp")
	liveCache := filepath.Join(cacheDir, "live.cache")
	for _, path := range []string{staleTemp, freshTemp, liveCache} {
		if err := os.WriteFile(path, []byte("payload"), 0o644); err != nil {
			t.Fatalf("write %s: %v", path, err)
		}
	}
	old := now.Add(-staleTempFileTTL - time.Minute)
	if err := os.Chtimes(staleTemp, old, old); err != nil {
		t.Fatalf("chtimes stale temp: %v", err)
	}

	if err := pruneAnalyzerCacheDir(cacheDir, now); err != nil {
		t.Fatalf("pruneAnalyzerCacheDir: %v", err)
	}

	if _, err := os.Stat(staleTemp); !os.IsNotExist(err) {
		t.Fatalf("expected stale temp file to be removed, stat err: %v", err)
	}
	for _, path := range []string{freshTemp, liveCache} {
		if _, err := os.Stat(path); err != nil {
			t.Fatalf("expected %s to be preserved: %v", path, err)
		}
	}
}

func TestSaveCacheToDiskLeavesNoTempFiles(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	target := filepath.Join(home, "target")
	if err := os.MkdirAll(target, 0o755); err != nil {
		t.Fatalf("create target: %v", err)
	}
	if err := saveCacheToDisk(target, scanResult{TotalSize: 2048, TotalFiles: 8}); err != nil {
		t.Fatalf("saveCacheToDisk: %v", err)
	}

	cacheDir, err := getCacheDir()
	if err != nil {
		t.Fatalf("getCacheDir: %v", err)
	}
	entries, err := os.ReadDir(cacheDir)
	if err != nil {
		t.Fatalf("read cache dir: %v", err)
	}
	for _, entry := range entries {
		if strings.HasSuffix(entry.Name(), ".tmp") {
			t.Fatalf("expected no temp file left behind, found %s", entry.Name())
		}
	}
	if _, err := loadCacheFromDisk(target); err != nil {
		t.Fatalf("expected the entry to be readable after an atomic save: %v", err)
	}
}

func TestPeekCacheTotalFilesRejectsSchemaMismatch(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	target := filepath.Join(home, "target")
	if err := os.MkdirAll(target, 0o755); err != nil {
		t.Fatalf("create target: %v", err)
	}
	cachePath, err := getCachePath(target)
	if err != nil {
		t.Fatalf("getCachePath: %v", err)
	}
	file, err := os.Create(cachePath)
	if err != nil {
		t.Fatalf("create cache: %v", err)
	}
	stale := cacheEntry{TotalFiles: 42, SchemaVersion: cacheSchemaVersion + 1, ScanTime: time.Now()}
	if err := gob.NewEncoder(file).Encode(stale); err != nil {
		file.Close() //nolint:errcheck
		t.Fatalf("encode stale entry: %v", err)
	}
	file.Close() //nolint:errcheck

	if _, err := peekCacheTotalFiles(target); err == nil {
		t.Fatalf("expected a schema mismatch to be rejected")
	}
	if _, err := os.Stat(cachePath); !os.IsNotExist(err) {
		t.Fatalf("expected the stale entry to be deleted, stat err: %v", err)
	}
}

// The analyzer store must not sit in the directory the shell side uses for its
// own state: the legacy sweep and the entry caps both assume they own it.
func TestGetCacheDirIsAnalyzerScoped(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	root, err := getMoleCacheRoot()
	if err != nil {
		t.Fatalf("getMoleCacheRoot: %v", err)
	}
	cacheDir, err := getCacheDir()
	if err != nil {
		t.Fatalf("getCacheDir: %v", err)
	}
	if want := filepath.Join(root, analyzerCacheDirName); cacheDir != want {
		t.Fatalf("cache dir = %q, want %q", cacheDir, want)
	}
	if _, err := os.Stat(cacheDir); err != nil {
		t.Fatalf("expected cache dir to be created: %v", err)
	}
}

func TestDirectoryScanPrunesCacheAfterCompletion(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	cacheDir, err := getCacheDir()
	if err != nil {
		t.Fatal(err)
	}
	stale := filepath.Join(cacheDir, "expired.cache")
	if err := os.WriteFile(stale, []byte("expired"), 0600); err != nil {
		t.Fatal(err)
	}
	old := time.Now().Add(-8 * 24 * time.Hour)
	if err := os.Chtimes(stale, old, old); err != nil {
		t.Fatal(err)
	}
	target := t.TempDir()
	var files, dirs, size int64
	current := &atomic.Value{}
	current.Store("")
	if _, err := scanPathConcurrentAllEntries(context.Background(), target, &files, &dirs, &size, current); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(stale); !os.IsNotExist(err) {
		t.Fatalf("completed scan left expired cache: %v", err)
	}
}

func TestCachePayloadRejectsOversizedAndNonregularFiles(t *testing.T) {
	dir := t.TempDir()
	huge := filepath.Join(dir, "huge.cache")
	f, err := os.Create(huge)
	if err != nil {
		t.Fatal(err)
	}
	if err := f.Truncate(cachePayloadMaxBytes + 1); err != nil {
		t.Fatal(err)
	}
	if err := f.Close(); err != nil {
		t.Fatal(err)
	}
	fifo := filepath.Join(dir, "fifo.cache")
	if err := syscall.Mkfifo(fifo, 0600); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(dir, "link.cache")
	if err := os.Symlink(huge, link); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{huge, fifo, dir, link} {
		if _, err := readCachePayload(path); err == nil {
			t.Errorf("accepted %s", path)
		}
	}
}

func TestLiveScanCompletionPrunesAfterItsRootCacheWrite(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	cacheDir, err := getCacheDir()
	if err != nil {
		t.Fatal(err)
	}
	stale := filepath.Join(cacheDir, "expired.cache")
	if err := os.WriteFile(stale, []byte("expired"), 0600); err != nil {
		t.Fatal(err)
	}
	old := time.Now().Add(-8 * 24 * time.Hour)
	if err := os.Chtimes(stale, old, old); err != nil {
		t.Fatal(err)
	}
	path := t.TempDir()
	m := newModel(path, false)
	defer m.cancelBackgroundCacheWrites(nil)
	m.finishLiveScan(scanResult{State: scanComplete, TotalSize: 1})
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(stale); os.IsNotExist(err) {
			cachePath, err := getCachePath(path)
			if err != nil {
				t.Fatal(err)
			}
			if _, err := os.Stat(cachePath); err != nil {
				t.Fatalf("maintenance ran before root save: %v", err)
			}
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("live scan left expired cache after completion")
}

func TestCancelCacheWriteDoesNotWaitForMaintenance(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	dir, err := getCacheDir()
	if err != nil {
		t.Fatal(err)
	}
	target := t.TempDir()
	ctx, cancel := context.WithCancel(context.Background())
	publication := newScanPublication(ctx, cancel)
	done := make(chan error, 1)
	analyzerCacheMu.Lock()
	locked := true
	defer func() {
		if locked {
			analyzerCacheMu.Unlock()
		}
	}()
	go func() {
		done <- saveCacheToDiskWithOptions(publication, target, scanResult{State: scanComplete, TotalSize: 1}, false)
	}()
	deadline := time.Now().Add(3 * time.Second)
	staged := false
	for time.Now().Before(deadline) {
		matches, err := filepath.Glob(filepath.Join(dir, "entry-*.tmp"))
		if err != nil {
			t.Fatal(err)
		}
		if len(matches) > 0 {
			staged = true
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if !staged {
		t.Fatal("writer did not reach staging")
	}
	canceled := make(chan struct{})
	go func() { publication.cancel(); close(canceled) }()
	select {
	case <-canceled:
	case <-time.After(time.Second):
		analyzerCacheMu.Unlock()
		locked = false
		<-canceled
		<-done
		t.Fatal("cancellation waited on cache maintenance")
	}
	analyzerCacheMu.Unlock()
	locked = false
	if err := <-done; !errors.Is(err, context.Canceled) {
		t.Fatalf("write after cancel: %v", err)
	}
	path, err := getCachePath(target)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("canceled cache published: %v", err)
	}
}

func TestCacheMaintenanceRefusesSymlinkRoots(t *testing.T) {
	for _, legacy := range []bool{false, true} {
		t.Run(fmt.Sprintf("legacy-%v", legacy), func(t *testing.T) {
			target := t.TempDir()
			victim := filepath.Join(target, "keep.cache")
			if err := os.WriteFile(victim, []byte("keep"), 0600); err != nil {
				t.Fatal(err)
			}
			old := time.Now().Add(-8 * 24 * time.Hour)
			if err := os.Chtimes(victim, old, old); err != nil {
				t.Fatal(err)
			}
			link := filepath.Join(t.TempDir(), "cache")
			if err := os.Symlink(target, link); err != nil {
				t.Fatal(err)
			}
			var err error
			if legacy {
				err = sweepLegacyAnalyzerCache(link)
			} else {
				err = pruneAnalyzerCacheDir(link, time.Now())
			}
			if err == nil {
				t.Error("accepted a symlink cache root")
			}
			if data, err := os.ReadFile(victim); err != nil || string(data) != "keep" {
				t.Fatalf("changed target outside cache: %q %v", data, err)
			}
		})
	}
}

func TestCacheUnlinkStaysInOpenedDirectoryAfterReplacement(t *testing.T) {
	parent := t.TempDir()
	root := filepath.Join(parent, "analyzer")
	moved := filepath.Join(parent, "original")
	other := t.TempDir()
	for _, dir := range []string{root, other} {
		if err := os.MkdirAll(dir, 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, "entry.cache"), []byte("keep"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	dir, err := openCacheMaintenanceDir(root)
	if err != nil {
		t.Fatal(err)
	}
	defer dir.Close() //nolint:errcheck
	if err := os.Rename(root, moved); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(other, root); err != nil {
		t.Fatal(err)
	}
	if err := removeCacheFile(dir, "entry.cache"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(moved, "entry.cache")); !os.IsNotExist(err) {
		t.Fatalf("original entry not pruned: %v", err)
	}
	if _, err := os.Stat(filepath.Join(other, "entry.cache")); err != nil {
		t.Fatalf("followed replacement symlink: %v", err)
	}
	if err := removeCacheFile(dir, "../entry.cache"); err == nil {
		t.Fatal("accepted a parent traversal")
	}
}

func TestCacheDirectoryRejectsPreexistingSymlink(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	root := filepath.Join(home, ".cache", "mole", "analyzer")
	if err := os.MkdirAll(filepath.Dir(root), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(t.TempDir(), root); err != nil {
		t.Fatal(err)
	}
	if _, err := getCacheDir(); err == nil {
		t.Fatal("accepted a symlink analyzer directory")
	}
}

func TestCacheInvalidationRefusesReplacedSymlinkRoot(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	target := t.TempDir()
	cachePath, err := getCachePath(target)
	if err != nil {
		t.Fatal(err)
	}
	cacheDir := filepath.Dir(cachePath)
	other := t.TempDir()
	victim := filepath.Join(other, filepath.Base(cachePath))
	if err := os.WriteFile(victim, []byte("keep"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(cacheDir, cacheDir+"-original"); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(other, cacheDir); err != nil {
		t.Fatal(err)
	}
	removeCacheEntry(target)
	if data, err := os.ReadFile(victim); err != nil || string(data) != "keep" {
		t.Fatalf("invalidation followed replacement: %q %v", data, err)
	}
}
