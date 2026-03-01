# Design and Evaluation of a Cross-Region Intelligent Load Balancer for Latency–Load Tradeoffs

**Proposal submitted by:**
- Stefan Arsov — sarsov@wisc.edu
- Zach Zemanovic — zemanovic@wisc.edu

---

## Motivation

Modern distributed applications are commonly deployed across multiple geographic regions to reduce user-perceived latency and improve availability. Load balancers play a critical role in routing client requests to appropriate compute resources. However, many existing load balancing strategies rely on single-metric or static decision policies, such as round-robin distribution or routing to the lowest-latency endpoint.

In practice, these approaches can lead to suboptimal performance under dynamic and asymmetric load conditions. For example, a region with low network latency may experience heavy compute saturation, resulting in increased queueing delays and degraded application performance. Conversely, a region with slightly higher network latency but lower compute utilization may provide a better overall user experience.

Commercial global load balancing solutions exist, but they are often expensive, proprietary, and difficult to evaluate or customize. There is limited publicly available experimental work that evaluates adaptive, multi-metric load balancing algorithms that explicitly balance network latency against real-time compute availability.

This project aims to investigate whether an intelligent, cross-region load balancer that incorporates multiple system signals can outperform traditional load balancing techniques, particularly with respect to tail latency and performance stability under uneven load.

---

## Summary

We propose to design, implement, and evaluate a software-based cross-region load balancer that dynamically routes client requests based on both network latency and compute resource utilization across multiple regions. This load balancer will evaluate the incoming client request and be able to determine the best compute resource to route it to.

Consider a client with low network latency to **Region A**, which is currently operating at 90% CPU utilization, and moderate latency to **Region B**, which has ample available compute capacity. A traditional latency-based load balancer would route the request to Region A, potentially resulting in long queueing delays.

An intelligent load balancer may instead route the request to Region B, accepting a modest increase in network latency in exchange for significantly improved compute availability. The resulting end-to-end response time may be lower, especially for latency-sensitive or CPU-intensive workloads.

---

## Research Component

The research objective of this project is to evaluate how different load balancing strategies affect application performance under varying network and compute conditions.

We will implement and compare the following categories of algorithms:

### Baseline Techniques
- Round-robin
- Lowest network latency
- Lowest CPU utilization
- Least number of active connections

### Intelligent Load Balancing Techniques
- Weighted multi-metric routing (latency + compute load)
- Adaptive scoring functions that dynamically adjust weights
- Threshold-based failover under regional saturation

### Evaluation Metrics
- End-to-end request response time
- Tail latency (p95 and p99)
- Throughput
- Request failure or timeout rate
- Performance stability under changing load

### Hypothesis

We hypothesize that multi-metric intelligent routing strategies will reduce tail latency and improve performance stability compared to single-metric approaches, particularly under asymmetric regional load conditions.

---

## Resources

To conduct this project, we will require multiple compute resources distributed across geographically distinct regions. These will be provisioned using:

- Azure student credits to deploy virtual machines in multiple regions
- A locally provisioned Mininet or equivalent VM for traffic generation and control

Azure regions will be used to emulate real-world WAN latency differences. Additional traffic shaping tools may be used to introduce controlled latency and load where necessary.

All required resources are accessible through existing student or course-provided infrastructure.

---

## Project Management

| Date | Items to Accomplish |
|------|---------------------|
| Feb 11 – 25 | Initial design document for load balancer implementation; VM provisioning and initial latency testing from various networks |
| Feb 25 – March 11 | Build POC load balancer, implementing standard load balancing techniques (Round Robin, lowest latency, lowest CPU, etc.) |
| March 11 – March 25 | Design and add intelligent load balancing |
| April 1 – April 15 | Tune intelligent load balancing to maximize performance |
| April 15 – April 29 | Full suite of standardized testing and research outcomes formally documented |
