package lb

import (
	"sync"
	"testing"
)

func TestRecordLatency_Average(t *testing.T) {
	b := &Backend{}
	b.RecordLatency(10)
	b.RecordLatency(20)
	b.RecordLatency(30)

	want := 20.0
	if b.AvgLatencyMs != want {
		t.Errorf("avg = %.2f, want %.2f", b.AvgLatencyMs, want)
	}
}

func TestRecordLatency_RollingWindow(t *testing.T) {
	b := &Backend{}
	// Fill the window with 1.0
	for i := 0; i < latencyHistorySize; i++ {
		b.RecordLatency(1.0)
	}
	// Push a large value in — oldest 1.0 should fall off
	b.RecordLatency(float64(latencyHistorySize + 1))

	// History should be capped at latencyHistorySize
	if len(b.LatencyHistory) != latencyHistorySize {
		t.Errorf("history len = %d, want %d", len(b.LatencyHistory), latencyHistorySize)
	}
	// Average must have shifted away from 1.0
	if b.AvgLatencyMs == 1.0 {
		t.Error("expected average to shift after window overflow")
	}
}

func TestRecordLatency_SingleSample(t *testing.T) {
	b := &Backend{}
	b.RecordLatency(42.5)
	if b.AvgLatencyMs != 42.5 {
		t.Errorf("avg = %.2f, want 42.50", b.AvgLatencyMs)
	}
}

func TestIncrDecrConns(t *testing.T) {
	b := &Backend{}
	b.IncrConns()
	b.IncrConns()
	if b.ActiveConns != 2 {
		t.Errorf("ActiveConns = %d, want 2", b.ActiveConns)
	}
	b.DecrConns()
	if b.ActiveConns != 1 {
		t.Errorf("ActiveConns = %d, want 1", b.ActiveConns)
	}
}

func TestIncrDecrConns_Concurrent(t *testing.T) {
	b := &Backend{}
	var wg sync.WaitGroup
	for i := 0; i < 100; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			b.IncrConns()
			b.DecrConns()
		}()
	}
	wg.Wait()
	if b.ActiveConns != 0 {
		t.Errorf("ActiveConns after balanced incr/decr = %d, want 0", b.ActiveConns)
	}
}

func TestStats_Snapshot(t *testing.T) {
	b := &Backend{
		ID:      "b1",
		URL:     "http://localhost:8081",
		Region:  "us-west",
		Healthy: true,
	}
	b.RecordLatency(50)
	b.IncrConns()

	s := b.Stats()

	if s.ID != "b1" {
		t.Errorf("ID = %q, want %q", s.ID, "b1")
	}
	if !s.Healthy {
		t.Error("expected Healthy=true")
	}
	if s.AvgLatencyMs != 50 {
		t.Errorf("AvgLatencyMs = %.2f, want 50.00", s.AvgLatencyMs)
	}
	if s.ActiveConns != 1 {
		t.Errorf("ActiveConns = %d, want 1", s.ActiveConns)
	}
}

func TestStats_DoesNotMutate(t *testing.T) {
	b := &Backend{ID: "b1", Healthy: true}
	b.RecordLatency(10)
	s1 := b.Stats()

	b.RecordLatency(90) // change the backend
	s2 := b.Stats()

	// s1 should be frozen at the time it was taken
	if s1.AvgLatencyMs == s2.AvgLatencyMs {
		// Consecutive averages differ only when the window shifts; with just 2
		// samples they will differ, so equality means Stats is aliasing state.
		t.Error("snapshots should be independent")
	}
}
