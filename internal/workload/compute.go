package workload

import (
	"crypto/sha256"
	"fmt"
	"runtime"
	"sync"
)

const iterationsPerUnit = 50_000

// RunCPUWork performs iterative SHA-256 hashing on a single goroutine.
// intensity is clamped to [1, 10]; each unit = 50,000 iterations.
func RunCPUWork(intensity int) string {
	if intensity < 1 {
		intensity = 1
	}
	if intensity > 10 {
		intensity = 10
	}

	iterations := intensity * iterationsPerUnit
	data := []byte("inteliLB-seed")

	for i := 0; i < iterations; i++ {
		sum := sha256.Sum256(data)
		data = sum[:]
	}

	return fmt.Sprintf("%x", data)
}

// RunCPUWorkParallel runs RunCPUWork on runtime.NumCPU() goroutines
// simultaneously, saturating all cores available to the container.
// This means a 1-core backend hits 100% CPU much faster under load than a
// 4-core backend, giving the intelligent/adaptive algorithms clear signal.
func RunCPUWorkParallel(intensity int) string {
	n := runtime.NumCPU()
	results := make([]string, n)

	var wg sync.WaitGroup
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func(idx int) {
			defer wg.Done()
			results[idx] = RunCPUWork(intensity)
		}(i)
	}
	wg.Wait()

	// Combine per-core results into a single hash
	combined := make([]byte, 0, n*64)
	for _, r := range results {
		combined = append(combined, r...)
	}
	sum := sha256.Sum256(combined)
	return fmt.Sprintf("%x", sum)
}
