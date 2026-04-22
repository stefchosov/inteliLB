package main

import (
	"context"
	"encoding/csv"
	"encoding/json"
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
	startedAt time.Time
	totalMs   float64 // end-to-end RTT measured by client
	computeMs float64 // CPU work time reported by backend (-1 if unavailable)
	networkMs float64 // totalMs - computeMs (-1 if unavailable)
	err       bool
}

type workResponse struct {
	DurationMs int64 `json:"duration_ms"`
}

func main() {
	targetURL := flag.String("url", "http://localhost:8080", "target load balancer URL")
	workers   := flag.Int("workers", 10, "concurrent workers")
	duration  := flag.Duration("duration", 30*time.Second, "test duration")
	intensity := flag.Int("intensity", 5, "work intensity (1-10)")
	output    := flag.String("output", "results.csv", "CSV output file")
	flag.Parse()

	workURL := fmt.Sprintf("%s/work?intensity=%d", *targetURL, *intensity)

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

	deadline := time.Now().Add(*duration)
	results  := make(chan result, 100000)

	var totalReqs   int64
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
				totalMs := float64(time.Since(start).Milliseconds())

				if err != nil {
					atomic.AddInt64(&totalErrors, 1)
					atomic.AddInt64(&totalReqs, 1)
					results <- result{startedAt: start, totalMs: totalMs, computeMs: -1, networkMs: -1, err: true}
					continue
				}

				body, _ := io.ReadAll(resp.Body)
				resp.Body.Close()

				isErr := resp.StatusCode >= 500
				if isErr {
					atomic.AddInt64(&totalErrors, 1)
				}
				atomic.AddInt64(&totalReqs, 1)

				var computeMs, networkMs float64
				var wr workResponse
				if jsonErr := json.Unmarshal(body, &wr); jsonErr == nil && wr.DurationMs > 0 {
					computeMs = float64(wr.DurationMs)
					networkMs = totalMs - computeMs
				} else {
					computeMs = -1
					networkMs = -1
				}

				results <- result{
					startedAt: start,
					totalMs:   totalMs,
					computeMs: computeMs,
					networkMs: networkMs,
					err:       isErr,
				}
			}
		}()
	}

	// Live stats
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
				cur  := atomic.LoadInt64(&totalReqs)
				rps  := cur - prevReqs
				prevReqs = cur
				errs := atomic.LoadInt64(&totalErrors)
				fmt.Printf("\r[%.0fs] reqs=%-6d  req/s=%-5d  errors=%-5d",
					time.Since(startTime).Seconds(), cur, rps, errs)
			}
		}
	}()

	go func() {
		wg.Wait()
		close(results)
	}()

	var allResults []result
	for r := range results {
		allResults = append(allResults, r)
	}
	fmt.Println()

	var total, compute, network []float64
	for _, r := range allResults {
		if r.err {
			continue
		}
		total = append(total, r.totalMs)
		if r.computeMs >= 0 {
			compute = append(compute, r.computeMs)
			network = append(network, r.networkMs)
		}
	}
	sort.Float64s(total)
	sort.Float64s(compute)
	sort.Float64s(network)

	fmt.Printf("Total requests : %d\n", len(allResults))
	fmt.Printf("Errors         : %d\n", atomic.LoadInt64(&totalErrors))
	if len(total) > 0 {
		fmt.Println()
		fmt.Printf("               %8s  %8s  %8s\n", "p50", "p95", "p99")
		fmt.Printf("Total RTT      %7.1fms  %7.1fms  %7.1fms\n",
			percentile(total, 50), percentile(total, 95), percentile(total, 99))
		if len(compute) > 0 {
			fmt.Printf("Compute        %7.1fms  %7.1fms  %7.1fms\n",
				percentile(compute, 50), percentile(compute, 95), percentile(compute, 99))
			fmt.Printf("Network        %7.1fms  %7.1fms  %7.1fms\n",
				percentile(network, 50), percentile(network, 95), percentile(network, 99))
		}
	}

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
	if err := w.Write([]string{"timestamp_ms", "total_ms", "compute_ms", "network_ms", "error"}); err != nil {
		return err
	}
	for _, r := range results {
		if err := w.Write([]string{
			strconv.FormatInt(r.startedAt.UnixMilli(), 10),
			strconv.FormatFloat(r.totalMs, 'f', 2, 64),
			strconv.FormatFloat(r.computeMs, 'f', 2, 64),
			strconv.FormatFloat(r.networkMs, 'f', 2, 64),
			strconv.FormatBool(r.err),
		}); err != nil {
			return err
		}
	}
	w.Flush()
	return w.Error()
}
