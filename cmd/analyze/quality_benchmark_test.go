//go:build darwin

package main

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
)

// Synthetic workloads are comparable receipts, not hard timing gates. No
// benchmark reads the developer's home or invokes Spotlight/Finder.
func BenchmarkQualityScan(b *testing.B) {
	for _, shape := range []string{"wide", "deep", "mixed"} {
		b.Run(shape, func(b *testing.B) {
			home := b.TempDir()
			b.Setenv("HOME", home)
			root := filepath.Join(home, "fixture")
			for i := range 128 {
				parent := root
				if shape == "deep" || (shape == "mixed" && i%8 == 0) {
					for depth := range 12 {
						parent = filepath.Join(parent, fmt.Sprintf("level-%02d", depth))
					}
				}
				if err := os.MkdirAll(parent, 0o700); err != nil {
					b.Fatal(err)
				}
				if err := os.WriteFile(filepath.Join(parent, fmt.Sprintf("file-%03d", i)), []byte("fixture"), 0o600); err != nil {
					b.Fatal(err)
				}
			}
			b.ReportAllocs()
			b.ResetTimer()
			for b.Loop() {
				var files, dirs, bytes int64
				var current atomic.Value
				current.Store("")
				publication := newScanPublication(context.Background(), nil)
				result, err := scanPathConcurrentWithLimiter(context.Background(), root, &files, &dirs, &bytes, &current,
					false, 0, newScanLimiter(128), scanCacheBypass, publication)
				publication.cancel()
				if err != nil || result.TotalFiles != 128 {
					b.Fatalf("scan did not finish the fixture: files=%d err=%v", result.TotalFiles, err)
				}
			}
		})
	}
}

func BenchmarkQualityFirstListing(b *testing.B) {
	root := b.TempDir()
	for i := range 256 {
		if err := os.WriteFile(filepath.Join(root, fmt.Sprintf("file-%03d", i)), nil, 0o600); err != nil {
			b.Fatal(err)
		}
	}
	b.ReportAllocs()
	b.ResetTimer()
	for b.Loop() {
		result, _, err := readLiveScanInitialEntries(root, newScanLimiter(256))
		if err != nil || len(result.Entries) != 256 {
			b.Fatalf("initial listing: entries=%d err=%v", len(result.Entries), err)
		}
	}
}
