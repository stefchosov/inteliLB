package main

import (
	"context"
	"encoding/csv"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"math/rand"
	"net/http"
	"os"
	"os/signal"
	"sort"
	"strconv"
	"strings"
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
	backendID string  // X-Backend-ID header set by LB
	workType  string
	err       bool
}

type workResponse struct {
	DurationMs int64  `json:"duration_ms"`
	WorkType   string `json:"work_type"`
}

// workSpec describes a single work type entry in the mix.
type workSpec struct {
	name      string // canonical name (used as workType when backend doesn't echo it)
	typeParam string // value of &type= query param
	intensity int    // 0 means use global --intensity
	weight    int
}

// parseMix parses a mix string like "cpu:50,io:30,cpu_light:20" into a slice of workSpec.
// globalIntensity is used for specs that don't override intensity.
func parseMix(mix string, globalIntensity int) ([]workSpec, error) {
	parts := strings.Split(mix, ",")
	specs := make([]workSpec, 0, len(parts))
	for _, part := range parts {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		kv := strings.SplitN(part, ":", 2)
		if len(kv) != 2 {
			return nil, fmt.Errorf("invalid mix entry %q (want name:weight)", part)
		}
		name := strings.TrimSpace(kv[0])
		weight, err := strconv.Atoi(strings.TrimSpace(kv[1]))
		if err != nil || weight <= 0 {
			return nil, fmt.Errorf("invalid weight in mix entry %q: %v", part, err)
		}

		var typeParam string
		var intensity int
		switch name {
		case "cpu":
			typeParam = "cpu"
			intensity = 0 // use global
		case "io":
			typeParam = "io"
			intensity = 0
		case "mixed":
			typeParam = "mixed"
			intensity = 0
		case "cpu_light":
			typeParam = "cpu"
			intensity = 2
		case "cpu_heavy":
			typeParam = "cpu"
			intensity = 9
		default:
			return nil, fmt.Errorf("unknown work type %q in mix", name)
		}
		_ = globalIntensity // resolved at URL-build time
		specs = append(specs, workSpec{
			name:      name,
			typeParam: typeParam,
			intensity: intensity,
			weight:    weight,
		})
	}
	if len(specs) == 0 {
		return nil, fmt.Errorf("mix is empty")
	}
	return specs, nil
}

// pickSpec selects a workSpec from the mix using weighted random selection.
func pickSpec(rng *rand.Rand, specs []workSpec) workSpec {
	total := 0
	for _, s := range specs {
		total += s.weight
	}
	n := rng.Intn(total)
	for _, s := range specs {
		n -= s.weight
		if n < 0 {
			return s
		}
	}
	return specs[len(specs)-1]
}

// buildURL constructs the request URL for a given spec.
func buildURL(base string, spec workSpec, globalIntensity int) string {
	intensity := spec.intensity
	if intensity == 0 {
		intensity = globalIntensity
	}
	return fmt.Sprintf("%s/work?intensity=%d&type=%s", base, intensity, spec.typeParam)
}

// doRequest fires a single HTTP request and sends the result to the channel.
func doRequest(client *http.Client, url string, specName string, results chan<- result) {
	start := time.Now()
	resp, err := client.Get(url)
	totalMs := float64(time.Since(start).Milliseconds())

	if err != nil {
		results <- result{
			startedAt: start,
			totalMs:   totalMs,
			computeMs: -1,
			networkMs: -1,
			workType:  specName,
			err:       true,
		}
		return
	}

	backendID := resp.Header.Get("X-Backend-ID")
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()

	isErr := resp.StatusCode >= 500

	var computeMs, networkMs float64
	var wr workResponse
	workType := specName
	if jsonErr := json.Unmarshal(body, &wr); jsonErr == nil {
		if wr.WorkType != "" {
			workType = wr.WorkType
		}
		if wr.DurationMs > 0 {
			computeMs = float64(wr.DurationMs)
			networkMs = totalMs - computeMs
		} else {
			computeMs = -1
			networkMs = -1
		}
	} else {
		computeMs = -1
		networkMs = -1
	}

	results <- result{
		startedAt: start,
		totalMs:   totalMs,
		computeMs: computeMs,
		networkMs: networkMs,
		backendID: backendID,
		workType:  workType,
		err:       isErr,
	}
}

func main() {
	targetURL  := flag.String("url", "http://localhost:8080", "target load balancer URL")
	workers    := flag.Int("workers", 10, "concurrent workers (closed-loop mode)")
	duration   := flag.Duration("duration", 30*time.Second, "test duration")
	intensity  := flag.Int("intensity", 5, "work intensity (1-10)")
	output     := flag.String("output", "results.csv", "CSV output file")
	mode       := flag.String("mode", "closed", "load mode: closed|open")
	rate       := flag.Int("rate", 0, "target req/s (open-loop mode)")
	mixStr     := flag.String("mix", "cpu:100", "workload mix as name:weight[,name:weight,...] (cpu,io,mixed,cpu_light,cpu_heavy)")
	maxInflight := flag.Int("max-inflight", 100000, "max in-flight requests before dropping (open-loop mode)")
	flag.Parse()

	if *mode == "open" && *rate <= 0 {
		log.Fatalf("--rate must be > 0 when --mode=open")
	}

	specs, err := parseMix(*mixStr, *intensity)
	if err != nil {
		log.Fatalf("invalid --mix: %v", err)
	}

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

	deadline := time.Now().Add(*duration)
	results  := make(chan result, 500000)

	var totalReqs    int64
	var totalErrors  int64
	var totalDropped int64

	switch *mode {
	case "closed":
		runClosed(ctx, deadline, *workers, *targetURL, *intensity, specs, results, &totalReqs, &totalErrors)
	case "open":
		runOpen(ctx, deadline, *rate, *maxInflight, *targetURL, *intensity, specs, results, &totalReqs, &totalErrors, &totalDropped)
	default:
		log.Fatalf("unknown --mode %q: must be closed or open", *mode)
	}

	// Live stats goroutine
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
				if *mode == "open" {
					dropped := atomic.LoadInt64(&totalDropped)
					fmt.Printf("\r[%.0fs] reqs=%-6d  req/s=%-5d  errors=%-5d  dropped=%-5d",
						time.Since(startTime).Seconds(), cur, rps, errs, dropped)
				} else {
					fmt.Printf("\r[%.0fs] reqs=%-6d  req/s=%-5d  errors=%-5d",
						time.Since(startTime).Seconds(), cur, rps, errs)
				}
			}
		}
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

	if *mode == "open" {
		dropped := atomic.LoadInt64(&totalDropped)
		if dropped > 0 {
			fmt.Printf("Dropped        : %d\n", dropped)
		}
	}

	if err := writeCSV(*output, allResults); err != nil {
		log.Printf("failed to write CSV: %v", err)
	} else {
		fmt.Printf("Results written to %s\n", *output)
	}
}

// runClosed runs the existing closed-loop worker model.
func runClosed(
	ctx context.Context,
	deadline time.Time,
	numWorkers int,
	targetURL string,
	globalIntensity int,
	specs []workSpec,
	results chan<- result,
	totalReqs *int64,
	totalErrors *int64,
) {
	var wg sync.WaitGroup
	for i := 0; i < numWorkers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			client := &http.Client{Timeout: 30 * time.Second}
			rng := rand.New(rand.NewSource(time.Now().UnixNano()))
			for time.Now().Before(deadline) {
				select {
				case <-ctx.Done():
					return
				default:
				}

				spec := pickSpec(rng, specs)
				url  := buildURL(targetURL, spec, globalIntensity)

				start := time.Now()
				resp, err := client.Get(url)
				totalMs := float64(time.Since(start).Milliseconds())

				if err != nil {
					atomic.AddInt64(totalErrors, 1)
					atomic.AddInt64(totalReqs, 1)
					results <- result{
						startedAt: start,
						totalMs:   totalMs,
						computeMs: -1,
						networkMs: -1,
						workType:  spec.name,
						err:       true,
					}
					continue
				}

				backendID := resp.Header.Get("X-Backend-ID")
				body, _ := io.ReadAll(resp.Body)
				resp.Body.Close()

				isErr := resp.StatusCode >= 500
				if isErr {
					atomic.AddInt64(totalErrors, 1)
				}
				atomic.AddInt64(totalReqs, 1)

				var computeMs, networkMs float64
				var wr workResponse
				workType := spec.name
				if jsonErr := json.Unmarshal(body, &wr); jsonErr == nil {
					if wr.WorkType != "" {
						workType = wr.WorkType
					}
					if wr.DurationMs > 0 {
						computeMs = float64(wr.DurationMs)
						networkMs = totalMs - computeMs
					} else {
						computeMs = -1
						networkMs = -1
					}
				} else {
					computeMs = -1
					networkMs = -1
				}

				results <- result{
					startedAt: start,
					totalMs:   totalMs,
					computeMs: computeMs,
					networkMs: networkMs,
					backendID: backendID,
					workType:  workType,
					err:       isErr,
				}
			}
		}()
	}

	go func() {
		wg.Wait()
		close(results)
	}()
}

// runOpen runs the open-loop mode firing at a fixed rate.
func runOpen(
	ctx context.Context,
	deadline time.Time,
	targetRate int,
	maxInflight int,
	targetURL string,
	globalIntensity int,
	specs []workSpec,
	results chan<- result,
	totalReqs *int64,
	totalErrors *int64,
	totalDropped *int64,
) {
	// drainCtx is cancelled to abort all in-flight HTTP requests during shutdown,
	// guaranteeing every goroutine exits before we close(results).
	drainCtx, cancelDrain := context.WithCancel(context.Background())
	client := &http.Client{Timeout: 60 * time.Second}

	batchSize := targetRate / 10
	if batchSize < 1 {
		batchSize = 1
	}

	var inFlight int64
	var wg sync.WaitGroup
	stopC := make(chan struct{})

	go func() {
		rng := rand.New(rand.NewSource(time.Now().UnixNano()))
		ticker := time.NewTicker(100 * time.Millisecond)
		defer ticker.Stop()

		for {
			select {
			case <-ctx.Done():
				return
			case <-stopC:
				return
			case t := <-ticker.C:
				if t.After(deadline) {
					return
				}
				for i := 0; i < batchSize; i++ {
					if atomic.LoadInt64(&inFlight) >= int64(maxInflight) {
						// Record dropped
						atomic.AddInt64(totalDropped, 1)
						atomic.AddInt64(totalReqs, 1)
						results <- result{
							startedAt: time.Now(),
							totalMs:   0,
							computeMs: -1,
							networkMs: -1,
							workType:  "dropped",
							err:       true,
						}
						continue
					}

					spec := pickSpec(rng, specs)
					url := buildURL(targetURL, spec, globalIntensity)

					atomic.AddInt64(&inFlight, 1)
					wg.Add(1)
					go func(u string, s workSpec) {
						defer wg.Done()
						defer atomic.AddInt64(&inFlight, -1)

						start := time.Now()
						req, _ := http.NewRequestWithContext(drainCtx, "GET", u, nil)
						resp, err := client.Do(req)
						totalMs := float64(time.Since(start).Milliseconds())

						if err != nil {
							atomic.AddInt64(totalErrors, 1)
							atomic.AddInt64(totalReqs, 1)
							results <- result{
								startedAt: start,
								totalMs:   totalMs,
								computeMs: -1,
								networkMs: -1,
								workType:  s.name,
								err:       true,
							}
							return
						}

						backendID := resp.Header.Get("X-Backend-ID")
						body, _ := io.ReadAll(resp.Body)
						resp.Body.Close()

						isErr := resp.StatusCode >= 500
						if isErr {
							atomic.AddInt64(totalErrors, 1)
						}
						atomic.AddInt64(totalReqs, 1)

						var computeMs, networkMs float64
						var wr workResponse
						workType := s.name
						if jsonErr := json.Unmarshal(body, &wr); jsonErr == nil {
							if wr.WorkType != "" {
								workType = wr.WorkType
							}
							if wr.DurationMs > 0 {
								computeMs = float64(wr.DurationMs)
								networkMs = totalMs - computeMs
							} else {
								computeMs = -1
								networkMs = -1
							}
						} else {
							computeMs = -1
							networkMs = -1
						}

						results <- result{
							startedAt: start,
							totalMs:   totalMs,
							computeMs: computeMs,
							networkMs: networkMs,
							backendID: backendID,
							workType:  workType,
							err:       isErr,
						}
					}(url, spec)
				}
			}
		}
	}()

	go func() {
		defer cancelDrain()

		select {
		case <-ctx.Done():
		case <-time.After(time.Until(deadline)):
		}

		// Stop ticker so no new wg.Add(1) can race wg.Wait().
		close(stopC)

		done := make(chan struct{})
		go func() { wg.Wait(); close(done) }()
		select {
		case <-done:
			// All goroutines finished naturally within the grace window.
		case <-time.After(5 * time.Second):
			// Abort all in-flight HTTP requests; goroutines exit with context.Canceled.
			cancelDrain()
			wg.Wait()
		}
		// Every goroutine has exited — safe to close.
		close(results)
	}()
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
	if err := w.Write([]string{"timestamp_ms", "total_ms", "compute_ms", "network_ms", "backend_id", "work_type", "error"}); err != nil {
		return err
	}
	for _, r := range results {
		if err := w.Write([]string{
			strconv.FormatInt(r.startedAt.UnixMilli(), 10),
			strconv.FormatFloat(r.totalMs, 'f', 2, 64),
			strconv.FormatFloat(r.computeMs, 'f', 2, 64),
			strconv.FormatFloat(r.networkMs, 'f', 2, 64),
			r.backendID,
			r.workType,
			strconv.FormatBool(r.err),
		}); err != nil {
			return err
		}
	}
	w.Flush()
	return w.Error()
}
