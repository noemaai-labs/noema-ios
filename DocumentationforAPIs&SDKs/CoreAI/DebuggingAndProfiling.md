# Inspecting, debugging, and profiling Core AI models

Three complementary tools for investigating model structure, runtime performance, and numerical correctness.

Source: https://developer.apple.com/documentation/coreai/inspecting-debugging-and-profiling-core-ai-models

## Overview

Apple provides three integrated tools that work together across the development lifecycle:

| Tool | When to use | Access |
|------|-------------|--------|
| **Core AI Debugger** | Inspect model structure, validate outputs against reference | Standalone macOS app |
| **Core AI Debug Gauge** | Monitor live load/specialize/inference events during a debug session | Xcode → Debug Navigator |
| **Core AI Instrument** | Profile detailed timing across CPU, GPU, Neural Engine | Instruments app |

## Core AI Debugger

A standalone macOS application that works directly with `.aimodel` files.

Capabilities:
* Inspect operation graph structure
* Browse function signatures (inputs, outputs, states) without running inference
* Validate numerical correctness: run inference through the debugger and compare outputs against a reference dataset
* Identify layers with unexpected output values or NaN/Inf

Workflow:
1. Open Core AI Debugger
2. Drag in your `.aimodel` file
3. Browse the model structure
4. Optionally load reference inputs and outputs to validate correctness

Related: Validating inference correctness against a reference run
[https://developer.apple.com/documentation/coreai/validating-inference-correctness-against-a-reference-run](https://developer.apple.com/documentation/coreai/validating-inference-correctness-against-a-reference-run)

## Core AI Debug Gauge

Built into Xcode's Debug Navigator. Tracks each model **load**, **specialization**, and **inference** event in real time during a debug session.

Use it to:
* Identify unexpected re-specialization (e.g., when `SpecializationOptions` changes between calls)
* Spot inference calls that are slower than expected
* Verify cache hits are occurring (no specialization events on subsequent launches)

To enable: Run your app via Xcode → open Debug Navigator → select the Core AI gauge.

Related: Monitoring model performance with the debug gauge
[https://developer.apple.com/documentation/coreai/monitoring-model-performance-with-the-debug-gauge](https://developer.apple.com/documentation/coreai/monitoring-model-performance-with-the-debug-gauge)

## Core AI Instrument

An Instruments template that profiles your app's Core AI activity with detailed timing across CPU, GPU, and Neural Engine.

Captures:
* **Inference duration** per call, broken down by compute unit
* **Memory bandwidth** consumed by weight loads
* **Queue depth** on the GPU command queue (via `ComputeStream`)
* **Cache hit/miss** events for specialization cache

To use:
1. Xcode → Product → Profile
2. Select the **Core AI** Instruments template
3. Record a trace while exercising your AI feature
4. Inspect the timeline for hotspots

Key insight: correlate CPU stalls with GPU/Neural Engine utilization to find pipeline gaps where the CPU is waiting for the GPU or vice versa.

Related: Analyzing model runtime performance with Instruments
[https://developer.apple.com/documentation/coreai/analyzing-model-runtime-performance-with-instruments](https://developer.apple.com/documentation/coreai/analyzing-model-runtime-performance-with-instruments)

## Recommended Debugging Workflow

1. **During model authoring** — use Core AI Debugger to validate the model structure and verify outputs match your reference implementation
2. **During integration** — use the Debug Gauge to confirm specialization is happening once and inference timing looks reasonable
3. **Before shipping** — run the Core AI Instrument to capture detailed timing and identify bottlenecks on target hardware

## Validating Numerical Correctness

If you observe unexpected inference results:

1. Export reference inputs/outputs from your training framework (PyTorch, JAX, etc.)
2. Open Core AI Debugger, load your `.aimodel`, and provide the reference inputs
3. Compare outputs — the debugger highlights layers where the values diverge

Related: Validating inference correctness against a reference run
[https://developer.apple.com/documentation/coreai/validating-inference-correctness-against-a-reference-run](https://developer.apple.com/documentation/coreai/validating-inference-correctness-against-a-reference-run)

## Common Issues

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| Slow first inference | Re-specializing every launch | Use `AIModelCache`, check cache hits in Debug Gauge |
| NaN/Inf outputs | Numeric precision issue in quantized layers | Use Core AI Debugger to bisect the layer causing it |
| GPU utilization low | CPU-bound input preprocessing | Move preprocessing to Metal or use `encode()` with `ComputeStream` |
| Unexpectedly high memory | Large intermediate buffers | Profile with Instruments; consider fp16 or int8 quantization |
