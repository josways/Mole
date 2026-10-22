//go:build darwin

package main

import (
	"fmt"
	"slices"
	"sort"
	"testing"
)

func FuzzCandidateOrdering(f *testing.F) {
	f.Add([]byte{0, 1, 1, 255})
	f.Add(bytesForCandidateSeed())
	f.Fuzz(func(t *testing.T, sizes []byte) {
		if len(sizes) > 512 {
			t.Skip()
		}
		files := make([]fileEntry, len(sizes))
		for i, size := range sizes {
			files[i] = fileEntry{Path: fmt.Sprintf("/fixture/%04d", i), Size: int64(size)}
		}
		want := slices.Clone(files)
		// Independent full-sort oracle for the bounded heap selection.
		sort.Slice(want, func(i, j int) bool {
			if want[i].Size == want[j].Size {
				return want[i].Path < want[j].Path
			}
			return want[i].Size > want[j].Size
		})
		want = want[:min(len(want), maxLargeFiles)]
		got := topLargeFiles(slices.Clone(files))
		if !slices.Equal(got, want) {
			t.Fatalf("heap selection differs from full sort: got %v want %v", got, want)
		}
		slices.Reverse(files)
		if reverse := topLargeFiles(files); !slices.Equal(reverse, want) {
			t.Fatal("candidate membership depends on discovery order")
		}
	})
}

func bytesForCandidateSeed() []byte {
	return make([]byte, maxLargeFiles*3)
}
