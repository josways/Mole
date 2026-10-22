//go:build darwin

package main

import (
	"bytes"
	"encoding/gob"
	"testing"
)

func FuzzCacheEntry(f *testing.F) {
	for _, schema := range []int{cacheSchemaVersion, cacheSchemaVersion - 1} {
		var encoded bytes.Buffer
		if err := gob.NewEncoder(&encoded).Encode(cacheEntry{SchemaVersion: schema, TotalSize: 4096, TotalFiles: 2}); err != nil {
			f.Fatal(err)
		}
		f.Add(encoded.Bytes())
	}
	f.Add([]byte("truncated cache"))
	f.Add([]byte{})
	f.Fuzz(func(t *testing.T, data []byte) {
		if len(data) > 64<<10 {
			t.Skip()
		}
		entry, err := decodeCacheEntry(bytes.NewReader(data))
		if err != nil {
			if entry != nil {
				t.Fatal("failed decode exposed a partial cache entry")
			}
			return
		}
		if entry.SchemaVersion != cacheSchemaVersion {
			t.Fatalf("accepted stale schema %d", entry.SchemaVersion)
		}
		// A successful read must survive re-encoding without losing the size,
		// coverage state or file count consumed by the TUI.
		var encoded bytes.Buffer
		if err := gob.NewEncoder(&encoded).Encode(entry); err != nil {
			t.Fatal(err)
		}
		again, err := decodeCacheEntry(&encoded)
		if err != nil || again.TotalSize != entry.TotalSize || again.TotalFiles != entry.TotalFiles || again.State != entry.State {
			t.Fatalf("cache round trip changed measurement: %v", err)
		}
	})
}
