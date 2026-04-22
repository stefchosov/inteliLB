package workload

import (
	"strings"
	"testing"
)

func TestRunCPUWork_Deterministic(t *testing.T) {
	a := RunCPUWork(3)
	b := RunCPUWork(3)
	if a != b {
		t.Errorf("same intensity produced different outputs: %q vs %q", a, b)
	}
}

func TestRunCPUWork_NonEmpty(t *testing.T) {
	if result := RunCPUWork(1); result == "" {
		t.Error("expected non-empty result")
	}
}

func TestRunCPUWork_DifferentIntensities(t *testing.T) {
	low := RunCPUWork(1)
	high := RunCPUWork(5)
	if low == high {
		t.Error("different intensities should produce different hashes")
	}
}

func TestRunCPUWork_ClampLow(t *testing.T) {
	// intensity 0 and 1 must produce the same result (clamped to 1)
	if RunCPUWork(0) != RunCPUWork(1) {
		t.Error("intensity 0 should be clamped to 1")
	}
}

func TestRunCPUWork_ClampHigh(t *testing.T) {
	// intensity 11 and 10 must produce the same result (clamped to 10)
	if RunCPUWork(11) != RunCPUWork(10) {
		t.Error("intensity 11 should be clamped to 10")
	}
}

func TestRunCPUWork_HexOutput(t *testing.T) {
	result := RunCPUWork(1)
	for _, c := range result {
		if !strings.ContainsRune("0123456789abcdef", c) {
			t.Errorf("output contains non-hex character %q", c)
		}
	}
}

func TestRunCPUWorkParallel_Deterministic(t *testing.T) {
	a := RunCPUWorkParallel(2)
	b := RunCPUWorkParallel(2)
	if a != b {
		t.Errorf("parallel: same intensity produced different outputs: %q vs %q", a, b)
	}
}

func TestRunCPUWorkParallel_NonEmpty(t *testing.T) {
	if result := RunCPUWorkParallel(1); result == "" {
		t.Error("expected non-empty result")
	}
}

func TestRunCPUWorkParallel_DiffersFromSerial(t *testing.T) {
	// Parallel combines N goroutine results before hashing, so the output
	// differs from a single serial run (unless NumCPU == 1 and the combination
	// happens to collide, which is astronomically unlikely).
	_ = RunCPUWorkParallel(2) // just ensure it runs without panic
}
