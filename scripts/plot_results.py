#!/usr/bin/env python3
"""
plot_results.py — Generate all figures for the inteliLB report.

Usage:
    python3 scripts/plot_results.py <results_dir> [output_dir]

Produces (in output_dir, default results_dir/figures/):
  fig1_throughput_by_profile.pdf
  fig2_p99_by_profile.pdf
  fig3_b1_share_by_profile.pdf
  fig4_saturation_throughput.pdf
  fig5_saturation_p50_p99.pdf
  fig6_saturation_errors.pdf
  fig7_backend_dist_cpu_only.pdf
"""

import csv
import json
import os
import sys
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.ticker as mticker
import numpy as np

# ── Config ────────────────────────────────────────────────────────────────────

ALGORITHMS = [
    "round_robin",
    "least_connections",
    "lowest_latency",
    "lowest_cpu",
    "intelligent",
    "adaptive",
]
ALGO_LABELS = {
    "round_robin":       "Round-Robin",
    "least_connections": "Least-Conn",
    "lowest_latency":    "Low-Latency",
    "lowest_cpu":        "Low-CPU",
    "intelligent":       "Intelligent",
    "adaptive":          "Adaptive",
}
PROFILES = ["cpu_only", "high_conn", "io_bound", "bimodal", "realistic"]
PROFILE_LABELS = {
    "cpu_only":  "CPU-Only",
    "high_conn": "High-Conn",
    "io_bound":  "IO-Bound",
    "bimodal":   "Bimodal",
    "realistic": "Realistic",
}
SAT_RATES = [10, 25, 50, 75, 100, 150, 200]
COLORS = {
    "round_robin":       "#4e79a7",
    "least_connections": "#f28e2b",
    "lowest_latency":    "#e15759",
    "lowest_cpu":        "#76b7b2",
    "intelligent":       "#59a14f",
    "adaptive":          "#b07aa1",
}

# ── Helpers ───────────────────────────────────────────────────────────────────

def load_csv(path):
    try:
        with open(path) as f:
            return list(csv.DictReader(f))
    except Exception:
        return []

def rps(rows):
    ts = [int(r["timestamp_ms"]) for r in rows if r.get("timestamp_ms")]
    if len(ts) < 2:
        return 0.0
    return len(ts) / ((max(ts) - min(ts)) / 1000.0)

def pct(rows, col, p):
    vals = []
    for r in rows:
        if r.get("error", "false") == "true":
            continue
        try:
            v = float(r[col])
            if v >= 0:
                vals.append(v)
        except (KeyError, ValueError):
            pass
    if not vals:
        return 0.0
    vals.sort()
    idx = max(0, int(len(vals) * p / 100) - 1)
    return vals[idx]

def err_pct(rows):
    if not rows:
        return 0.0
    return sum(1 for r in rows if r.get("error", "false") == "true") / len(rows) * 100

def b1_share(stats_path):
    try:
        with open(stats_path) as f:
            d = json.load(f)
        backs = d.get("backends", [])
        tot = sum(b.get("total_requests", 0) for b in backs)
        b1 = next((b.get("total_requests", 0) for b in backs if b["id"] == "backend-1"), 0)
        return b1 / tot * 100 if tot > 0 else 0.0
    except Exception:
        return 0.0

def save(fig, path):
    fig.savefig(path, bbox_inches="tight", dpi=150)
    plt.close(fig)
    print(f"  saved {path}")

# ── Figure 1: Throughput by profile ──────────────────────────────────────────

def fig_throughput(results_dir, out):
    profiles = [p for p in PROFILES if (results_dir / p).is_dir()]
    n_prof = len(profiles)
    n_algo = len(ALGORITHMS)
    x = np.arange(n_prof)
    width = 0.13

    fig, ax = plt.subplots(figsize=(11, 5))
    for i, algo in enumerate(ALGORITHMS):
        vals = []
        for prof in profiles:
            rows = load_csv(results_dir / prof / f"{algo}.csv")
            vals.append(rps(rows) if rows else 0.0)
        offset = (i - n_algo / 2 + 0.5) * width
        bars = ax.bar(x + offset, vals, width, label=ALGO_LABELS[algo],
                      color=COLORS[algo], edgecolor="white", linewidth=0.5)

    ax.set_xticks(x)
    ax.set_xticklabels([PROFILE_LABELS[p] for p in profiles], fontsize=11)
    ax.set_ylabel("Throughput (req/s)", fontsize=11)
    ax.set_title("Throughput by Workload Profile and Algorithm", fontsize=13, fontweight="bold")
    ax.legend(fontsize=9, ncol=3, loc="upper right")
    ax.yaxis.set_minor_locator(mticker.AutoMinorLocator())
    ax.grid(axis="y", linestyle="--", alpha=0.5)
    fig.tight_layout()
    save(fig, out / "fig1_throughput_by_profile.pdf")

# ── Figure 2: p99 latency by profile ─────────────────────────────────────────

def fig_p99(results_dir, out):
    profiles = [p for p in PROFILES if (results_dir / p).is_dir()
                and p != "io_bound"]   # io_bound compresses scale — shown separately
    n_prof = len(profiles)
    n_algo = len(ALGORITHMS)
    x = np.arange(n_prof)
    width = 0.13

    fig, ax = plt.subplots(figsize=(11, 5))
    for i, algo in enumerate(ALGORITHMS):
        vals = []
        for prof in profiles:
            rows = load_csv(results_dir / prof / f"{algo}.csv")
            vals.append(pct(rows, "total_ms", 99) / 1000 if rows else 0.0)
        offset = (i - n_algo / 2 + 0.5) * width
        ax.bar(x + offset, vals, width, label=ALGO_LABELS[algo],
               color=COLORS[algo], edgecolor="white", linewidth=0.5)

    ax.set_xticks(x)
    ax.set_xticklabels([PROFILE_LABELS[p] for p in profiles], fontsize=11)
    ax.set_ylabel("p99 Latency (s)", fontsize=11)
    ax.set_title("p99 Latency by Workload Profile (CPU-bound profiles, excludes IO-Bound)",
                 fontsize=12, fontweight="bold")
    ax.legend(fontsize=9, ncol=3, loc="upper right")
    ax.yaxis.set_minor_locator(mticker.AutoMinorLocator())
    ax.grid(axis="y", linestyle="--", alpha=0.5)
    fig.tight_layout()
    save(fig, out / "fig2_p99_by_profile.pdf")

# ── Figure 3: b1 share by profile ────────────────────────────────────────────

def fig_b1_share(results_dir, out):
    profiles = [p for p in PROFILES if (results_dir / p).is_dir()]
    n_prof = len(profiles)
    n_algo = len(ALGORITHMS)
    x = np.arange(n_prof)
    width = 0.13

    fig, ax = plt.subplots(figsize=(11, 5))
    for i, algo in enumerate(ALGORITHMS):
        vals = []
        for prof in profiles:
            share = b1_share(results_dir / prof / f"{algo}_stats.json")
            vals.append(share)
        offset = (i - n_algo / 2 + 0.5) * width
        ax.bar(x + offset, vals, width, label=ALGO_LABELS[algo],
               color=COLORS[algo], edgecolor="white", linewidth=0.5)

    ax.axhline(y=33.3, color="black", linestyle="--", linewidth=1,
               label="Round-Robin ideal (33.3%)")
    ax.axhline(y=14.3, color="gray", linestyle=":", linewidth=1,
               label="Capacity-ideal (14.3%)")
    ax.set_xticks(x)
    ax.set_xticklabels([PROFILE_LABELS[p] for p in profiles], fontsize=11)
    ax.set_ylabel("Backend-1 Share (%)", fontsize=11)
    ax.set_title("Traffic Share to Backend-1 (westus2, 1 vCPU — weakest backend)",
                 fontsize=12, fontweight="bold")
    ax.set_ylim(0, 105)
    ax.legend(fontsize=9, ncol=2, loc="upper right")
    ax.grid(axis="y", linestyle="--", alpha=0.5)
    fig.tight_layout()
    save(fig, out / "fig3_b1_share_by_profile.pdf")

# ── Figure 4: Saturation — achieved throughput ───────────────────────────────

def fig_sat_throughput(results_dir, out):
    sat_dir = results_dir / "saturation"
    if not sat_dir.is_dir():
        print("  skipping fig4 — no saturation dir")
        return

    fig, ax = plt.subplots(figsize=(9, 5))
    for algo in ALGORITHMS:
        xs, ys = [], []
        for rate in SAT_RATES:
            rows = load_csv(sat_dir / f"{algo}_rate{rate}.csv")
            if rows:
                xs.append(rate)
                ys.append(rps(rows))
        if xs:
            ax.plot(xs, ys, marker="o", label=ALGO_LABELS[algo],
                    color=COLORS[algo], linewidth=2, markersize=6)

    # Ideal line
    ax.plot(SAT_RATES, SAT_RATES, color="black", linestyle="--",
            linewidth=1, label="Ideal (achieved = offered)", alpha=0.5)

    ax.set_xlabel("Offered Load (req/s)", fontsize=11)
    ax.set_ylabel("Achieved Throughput (req/s)", fontsize=11)
    ax.set_title("Saturation Ramp — Achieved vs. Offered Load",
                 fontsize=13, fontweight="bold")
    ax.legend(fontsize=9, ncol=2)
    ax.grid(linestyle="--", alpha=0.4)
    fig.tight_layout()
    save(fig, out / "fig4_saturation_throughput.pdf")

# ── Figure 5: Saturation — p50 and p99 latency ───────────────────────────────

def fig_sat_latency(results_dir, out):
    sat_dir = results_dir / "saturation"
    if not sat_dir.is_dir():
        return

    fig, axes = plt.subplots(1, 2, figsize=(13, 5), sharey=False)
    for algo in ALGORITHMS:
        p50s, p99s, xs = [], [], []
        for rate in SAT_RATES:
            rows = load_csv(sat_dir / f"{algo}_rate{rate}.csv")
            if rows:
                xs.append(rate)
                p50s.append(pct(rows, "total_ms", 50) / 1000)
                p99s.append(pct(rows, "total_ms", 99) / 1000)
        if xs:
            axes[0].plot(xs, p50s, marker="o", label=ALGO_LABELS[algo],
                         color=COLORS[algo], linewidth=2, markersize=5)
            axes[1].plot(xs, p99s, marker="s", label=ALGO_LABELS[algo],
                         color=COLORS[algo], linewidth=2, markersize=5)

    for ax, title in zip(axes, ["p50 Latency (s)", "p99 Latency (s)"]):
        ax.set_xlabel("Offered Load (req/s)", fontsize=11)
        ax.set_ylabel(title, fontsize=11)
        ax.set_title(title, fontsize=12, fontweight="bold")
        ax.legend(fontsize=8, ncol=2)
        ax.grid(linestyle="--", alpha=0.4)

    fig.suptitle("Saturation Ramp — Latency vs. Offered Load",
                 fontsize=13, fontweight="bold")
    fig.tight_layout()
    save(fig, out / "fig5_saturation_latency.pdf")

# ── Figure 6: Saturation — error rate ────────────────────────────────────────

def fig_sat_errors(results_dir, out):
    sat_dir = results_dir / "saturation"
    if not sat_dir.is_dir():
        return

    fig, ax = plt.subplots(figsize=(9, 5))
    for algo in ALGORITHMS:
        xs, ys = [], []
        for rate in SAT_RATES:
            rows = load_csv(sat_dir / f"{algo}_rate{rate}.csv")
            if rows:
                xs.append(rate)
                ys.append(err_pct(rows))
        if xs:
            ax.plot(xs, ys, marker="o", label=ALGO_LABELS[algo],
                    color=COLORS[algo], linewidth=2, markersize=6)

    ax.axhline(y=1.0, color="red", linestyle="--", linewidth=1,
               alpha=0.7, label="1% error threshold")
    ax.set_xlabel("Offered Load (req/s)", fontsize=11)
    ax.set_ylabel("Error Rate (%)", fontsize=11)
    ax.set_title("Saturation Ramp — Error Rate vs. Offered Load",
                 fontsize=13, fontweight="bold")
    ax.legend(fontsize=9, ncol=2)
    ax.grid(linestyle="--", alpha=0.4)
    fig.tight_layout()
    save(fig, out / "fig6_saturation_errors.pdf")

# ── Figure 7: Backend distribution on cpu_only ───────────────────────────────

def fig_backend_dist(results_dir, out):
    prof_dir = results_dir / "cpu_only"
    if not prof_dir.is_dir():
        return

    backends = ["backend-1", "backend-2", "backend-3"]
    backend_labels = ["b1\n(1 vCPU\nwestus2)", "b2\n(2 vCPU\nnorthcentralus)", "b3\n(4 vCPU\neastus2)"]
    x = np.arange(len(backends))
    width = 0.13
    n_algo = len(ALGORITHMS)

    fig, ax = plt.subplots(figsize=(9, 5))
    for i, algo in enumerate(ALGORITHMS):
        try:
            with open(prof_dir / f"{algo}_stats.json") as f:
                d = json.load(f)
            backs = {b["id"]: b.get("total_requests", 0) for b in d.get("backends", [])}
            tot = sum(backs.values())
            vals = [backs.get(b, 0) / tot * 100 if tot > 0 else 0 for b in backends]
        except Exception:
            vals = [0, 0, 0]
        offset = (i - n_algo / 2 + 0.5) * width
        ax.bar(x + offset, vals, width, label=ALGO_LABELS[algo],
               color=COLORS[algo], edgecolor="white", linewidth=0.5)

    # Capacity-ideal
    ideal = [1/7*100, 2/7*100, 4/7*100]
    for xi, v in zip(x, ideal):
        ax.plot([xi - n_algo*width/2, xi + n_algo*width/2], [v, v],
                color="black", linestyle=":", linewidth=1.5)
    ax.plot([], [], color="black", linestyle=":", linewidth=1.5,
            label="Capacity-ideal (1:2:4)")

    ax.set_xticks(x)
    ax.set_xticklabels(backend_labels, fontsize=10)
    ax.set_ylabel("Request Share (%)", fontsize=11)
    ax.set_title("Backend Traffic Distribution — CPU-Only Profile",
                 fontsize=13, fontweight="bold")
    ax.legend(fontsize=9, ncol=2)
    ax.grid(axis="y", linestyle="--", alpha=0.4)
    fig.tight_layout()
    save(fig, out / "fig7_backend_dist_cpu_only.pdf")

# ── Main ─────────────────────────────────────────────────────────────────────

def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <results_dir> [output_dir]")
        sys.exit(1)

    results_dir = Path(sys.argv[1])
    out = Path(sys.argv[2]) if len(sys.argv) > 2 else results_dir / "figures"
    out.mkdir(parents=True, exist_ok=True)

    print(f"Results: {results_dir}")
    print(f"Output:  {out}")

    fig_throughput(results_dir, out)
    fig_p99(results_dir, out)
    fig_b1_share(results_dir, out)
    fig_sat_throughput(results_dir, out)
    fig_sat_latency(results_dir, out)
    fig_sat_errors(results_dir, out)
    fig_backend_dist(results_dir, out)

    print("\nDone.")

if __name__ == "__main__":
    main()
