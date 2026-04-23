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

// RunCPUWorkParallel divides intensity * iterationsPerUnit rounds evenly
// across runtime.NumCPU() goroutines so that total work per request is
// constant regardless of core count. A 4-vCPU backend completes the same
// request in ¼ the wall time of a 1-vCPU backend, correctly modelling
// compute capacity scaling.
func RunCPUWorkParallel(intensity int) string {
	if intensity < 1 {
		intensity = 1
	}
	if intensity > 10 {
		intensity = 10
	}

	n := runtime.NumCPU()
	totalIter := intensity * iterationsPerUnit
	perCore := totalIter / n
	if perCore < 1 {
		perCore = 1
	}

	results := make([]string, n)
	var wg sync.WaitGroup
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func(idx int) {
			defer wg.Done()
			data := []byte("inteliLB-seed")
			for j := 0; j < perCore; j++ {
				sum := sha256.Sum256(data)
				data = sum[:]
			}
			results[idx] = fmt.Sprintf("%x", data)
		}(i)
	}
	wg.Wait()

	combined := make([]byte, 0, n*64)
	for _, r := range results {
		combined = append(combined, r...)
	}
	sum := sha256.Sum256(combined)
	return fmt.Sprintf("%x", sum)
}
