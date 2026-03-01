package main

import (
	"context"
	"encoding/csv"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/signal"
	"sort"
	"strconv"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

type result struct {
	startedAt  time.Time
	durationMs float64
	err        bool
}

func main() {
	targetURL := flag.String("url", "http://localhost:8080", "target load balancer URL")
	workers := flag.Int("workers", 10, "concurrent workers")
	duration := flag.Duration("duration", 30*time.Second, "test duration")
	intensity := flag.Int("intensity", 5, "work intensity (1-10)")
	output := flag.String("output", "results.csv", "CSV output file")
	flag.Parse()

	workURL := fmt.Sprintf("%s/work?intensity=%d", *targetURL, *intensity)

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

	deadline := time.Now().Add(*duration)
	results := make(chan result, 100000)

	var totalReqs int64
	var totalErrors int64

	var wg sync.WaitGroup
	for i := 0; i < *workers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			client := &http.Client{Timeout: 30 * time.Second}
			for time.Now().Before(deadline) {
				select {
				case <-ctx.Done():
					return
				default:
				}

				start := time.Now()
				resp, err := client.Get(workURL)
				elapsed := float64(time.Since(start).Milliseconds())

				if err != nil {
					atomic.AddInt64(&totalErrors, 1)
					atomic.AddInt64(&totalReqs, 1)
					results <- result{startedAt: start, durationMs: elapsed, err: true}
					continue
				}
				io.Copy(io.Discard, resp.Body)
				resp.Body.Close()

				isErr := resp.StatusCode >= 500
				if isErr {
					atomic.AddInt64(&totalErrors, 1)
				}
				atomic.AddInt64(&totalReqs, 1)
				results <- result{startedAt: start, durationMs: elapsed, err: isErr}
			}
		}()
	}

	// Live stats — print every second
	go func() {
		ticker := time.NewTicker(time.Second)
		defer ticker.Stop()
		var prevReqs int64
		startTime := time.Now()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				cur := atomic.LoadInt64(&totalReqs)
				rps := cur - prevReqs
				prevReqs = cur
				errs := atomic.LoadInt64(&totalErrors)
				fmt.Printf("\r[%.0fs] reqs=%-6d  req/s=%-5d  errors=%-5d",
					time.Since(startTime).Seconds(), cur, rps, errs)
			}
		}
	}()

	// Wait for workers, then close results channel
	go func() {
		wg.Wait()
		close(results)
	}()

	// Drain results
	var allResults []result
	for r := range results {
		allResults = append(allResults, r)
	}
	fmt.Println()

	// Compute and print percentile summary
	var latencies []float64
	for _, r := range allResults {
		if !r.err {
			latencies = append(latencies, r.durationMs)
		}
	}
	sort.Float64s(latencies)

	fmt.Printf("Total requests : %d\n", len(allResults))
	fmt.Printf("Errors         : %d\n", atomic.LoadInt64(&totalErrors))
	if len(latencies) > 0 {
		fmt.Printf("p50            : %.1f ms\n", percentile(latencies, 50))
		fmt.Printf("p95            : %.1f ms\n", percentile(latencies, 95))
		fmt.Printf("p99            : %.1f ms\n", percentile(latencies, 99))
	}

	// Write results CSV
	if err := writeCSV(*output, allResults); err != nil {
		log.Printf("failed to write CSV: %v", err)
	} else {
		fmt.Printf("Results written to %s\n", *output)
	}
}

func percentile(sorted []float64, p float64) float64 {
	if len(sorted) == 0 {
		return 0
	}
	idx := int(float64(len(sorted)-1) * p / 100.0)
	return sorted[idx]
}

func writeCSV(path string, results []result) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer f.Close()

	w := csv.NewWriter(f)
	if err := w.Write([]string{"timestamp_ms", "duration_ms", "error"}); err != nil {
		return err
	}
	for _, r := range results {
		if err := w.Write([]string{
			strconv.FormatInt(r.startedAt.UnixMilli(), 10),
			strconv.FormatFloat(r.durationMs, 'f', 2, 64),
			strconv.FormatBool(r.err),
		}); err != nil {
			return err
		}
	}
	w.Flush()
	return w.Error()
}
