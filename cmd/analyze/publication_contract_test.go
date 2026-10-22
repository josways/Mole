//go:build darwin

package main

import (
	"context"
	"errors"
	"sync"
	"testing"
)

func TestCanceledPublicationContract(t *testing.T) {
	publication := newScanPublication(context.Background(), nil)
	calls := 0
	if err := publication.commit(func() error { calls++; return nil }); err != nil || calls != 1 {
		t.Fatalf("active publication did not commit: calls=%d err=%v", calls, err)
	}
	publication.cancel()
	err := publication.commit(func() error { calls++; return nil })
	if !errors.Is(err, context.Canceled) || calls != 1 {
		t.Fatalf("canceled publication committed: calls=%d err=%v", calls, err)
	}
}

func TestPublicationCancelJoinsConcurrentCommitters(t *testing.T) {
	publication := newScanPublication(context.Background(), nil)
	var workers sync.WaitGroup
	start := make(chan struct{})
	for range 16 {
		workers.Go(func() {
			<-start
			_ = publication.commit(func() error { return nil })
		})
	}
	close(start)
	publication.cancel()
	workers.Wait()
	if err := publication.commit(func() error {
		t.Error("publication ran after cancel returned")
		return nil
	}); !errors.Is(err, context.Canceled) {
		t.Fatalf("post-cancel commit: %v", err)
	}
}
