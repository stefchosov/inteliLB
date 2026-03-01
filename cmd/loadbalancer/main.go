package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/inteliLB/internal/lb"
)

func main() {
	port := flag.Int("port", 8080, "listen port")
	algorithm := flag.String("algorithm", "round_robin", "load balancing algorithm")
	backendsFlag := flag.String("backends", "", "comma-separated backend URLs")
	flag.Parse()

	// Env var overrides
	if v := os.Getenv("PORT"); v != "" {
		fmt.Sscanf(v, "%d", port)
	}
	if v := os.Getenv("ALGORITHM"); v != "" {
		*algorithm = v
	}
	if v := os.Getenv("BACKENDS"); v != "" {
		*backendsFlag = v
	}

	if *backendsFlag == "" {
		log.Fatal("no backends specified — use -backends or BACKENDS env var")
	}

	backendURLs := strings.Split(*backendsFlag, ",")
	for i, u := range backendURLs {
		backendURLs[i] = strings.TrimSpace(u)
	}

	balancer, err := lb.New(lb.Config{
		BackendURLs:    backendURLs,
		Algorithm:      *algorithm,
		PollInterval:   5 * time.Second,
		HealthInterval: 5 * time.Second,
	})
	if err != nil {
		log.Fatalf("failed to create balancer: %v", err)
	}
	balancer.Start()
	defer balancer.Stop()

	mux := http.NewServeMux()

	// Stats endpoint
	mux.HandleFunc("/lb/stats", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(balancer.Stats())
	})

	// Algorithm hot-swap endpoint
	mux.HandleFunc("/lb/algorithm", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		var body struct {
			Algorithm string `json:"algorithm"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			http.Error(w, "invalid JSON", http.StatusBadRequest)
			return
		}
		switch body.Algorithm {
		case lb.AlgoRoundRobin, lb.AlgoLowestLatency, lb.AlgoLowestCPU,
			lb.AlgoLeastConnections, lb.AlgoIntelligent, lb.AlgoAdaptive:
		default:
			http.Error(w, "unknown algorithm", http.StatusBadRequest)
			return
		}
		balancer.SetAlgorithm(body.Algorithm)
		log.Printf("algorithm switched to %s", body.Algorithm)
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]string{"algorithm": body.Algorithm})
	})

	// Proxy everything else
	mux.Handle("/", balancer)

	addr := fmt.Sprintf(":%d", *port)
	log.Printf("load balancer starting on %s with algorithm=%s backends=%v",
		addr, *algorithm, backendURLs)
	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Fatal(err)
	}
}
