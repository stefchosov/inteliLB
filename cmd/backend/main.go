package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"runtime"
	"strconv"
	"sync/atomic"
	"time"

	"github.com/inteliLB/internal/workload"
	"github.com/shirou/gopsutil/v3/cpu"
	"github.com/shirou/gopsutil/v3/mem"
)

var (
	activeConns int64
)

func main() {
	port      := flag.Int("port", 8080, "listen port")
	region    := flag.String("region", "us-east", "region label")
	id        := flag.String("id", "backend-1", "backend ID")
	latencyMs := flag.Int("simulated-latency-ms", 0, "artificial one-way network latency in ms")
	maxProcs  := flag.Int("max-procs", 0, "set GOMAXPROCS (0 = use runtime default)")
	flag.Parse()

	if *maxProcs > 0 {
		runtime.GOMAXPROCS(*maxProcs)
	}

	// Allow env var overrides
	if v := os.Getenv("PORT"); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			*port = n
		}
	}
	if v := os.Getenv("REGION"); v != "" {
		*region = v
	}
	if v := os.Getenv("ID"); v != "" {
		*id = v
	}
	if v := os.Getenv("SIMULATED_LATENCY_MS"); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			*latencyMs = n
		}
	}
	if v := os.Getenv("MAX_PROCS"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			runtime.GOMAXPROCS(n)
		}
	}

	mux := http.NewServeMux()

	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]string{
			"status": "ok",
			"region": *region,
			"id":     *id,
		})
	})

	mux.HandleFunc("/metrics", func(w http.ResponseWriter, r *http.Request) {
		cpuPct := getCPU()
		memPct := getMemory()
		conns := atomic.LoadInt64(&activeConns)

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]interface{}{
			"cpu_percent":          cpuPct,
			"memory_percent":       memPct,
			"active_connections":   conns,
			"num_cpus":             runtime.NumCPU(),
			"gomaxprocs":           runtime.GOMAXPROCS(0),
			"simulated_latency_ms": *latencyMs,
			"region":               *region,
			"id":                   *id,
		})
	})

	mux.HandleFunc("/work", func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt64(&activeConns, 1)
		defer atomic.AddInt64(&activeConns, -1)

		if *latencyMs > 0 {
			time.Sleep(time.Duration(*latencyMs) * time.Millisecond)
		}

		q := r.URL.Query()

		intensity := 5
		if v := q.Get("intensity"); v != "" {
			if n, err := strconv.Atoi(v); err == nil {
				intensity = n
			}
		}

		workType := "cpu"
		if v := q.Get("type"); v == "io" || v == "mixed" {
			workType = v
		}

		// Default io_ms = intensity * 50; override with ?io_ms=N
		ioMs := intensity * 50
		if v := q.Get("io_ms"); v != "" {
			if n, err := strconv.Atoi(v); err == nil {
				ioMs = n
			}
		}

		start := time.Now()
		var hash string
		var ioMsActual int

		switch workType {
		case "io":
			ioMsActual = ioMs
			time.Sleep(time.Duration(ioMs) * time.Millisecond)
		case "mixed":
			ioMsActual = ioMs
			time.Sleep(time.Duration(ioMs) * time.Millisecond)
			hash = workload.RunCPUWorkParallel(intensity)
		default: // "cpu"
			hash = workload.RunCPUWorkParallel(intensity)
		}

		durationMs := time.Since(start).Milliseconds()

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]interface{}{
			"result":        hash,
			"duration_ms":   durationMs,
			"work_type":     workType,
			"io_ms_actual":  ioMsActual,
			"region":        *region,
			"id":            *id,
		})
	})

	addr := fmt.Sprintf(":%d", *port)
	log.Printf("backend %s (%s) listening on %s", *id, *region, addr)
	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Fatal(err)
	}
}

func getCPU() float64 {
	pcts, err := cpu.Percent(200*time.Millisecond, false)
	if err != nil || len(pcts) == 0 {
		return 0
	}
	return pcts[0]
}

func getMemory() float64 {
	v, err := mem.VirtualMemory()
	if err != nil {
		return 0
	}
	return v.UsedPercent
}
