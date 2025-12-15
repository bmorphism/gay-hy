# Gay Distributed Color Bandwidth Protocol

## Overview

**Target: 10+ billion colors/sec across 34 machines**

The Gay protocol enables **fearless distributed color mining** with cryptographic verification that all peers computed identical results.

## Current Benchmarks (500M colors @ IHOR seed 7202985)

| Strategy | causality (M3 Max) | hatchery (M2) | Combined |
|----------|-------------------|---------------|----------|
| **fearless-128** | **2.03 B/sec** | **1.62 B/sec** | **3.65 B/sec** |
| fearless-256 | 1.31 B/sec | 1.10 B/sec | 2.41 B/sec |
| gigafearless | 994 M/sec | 1.17 B/sec | 2.16 B/sec |
| terastream | 149 M/sec | 413 M/sec | 562 M/sec |

**Fingerprint verification**: `fp=0xab11046c` ✓ MATCH  
**Triadic XOR**: `0x4815e08adab9dcfe` ✓ MATCH

### Projected 34-Machine Performance

| Machines | Est. Bandwidth | Time for 1T colors |
|----------|---------------|-------------------|
| 2 | 3.65 B/sec | 4.6 min |
| 10 | 15 B/sec | 67 sec |
| 34 | **50+ B/sec** | **20 sec** |

## Core Guarantees (SPI)

**Strong Parallelism Invariance**:
```
color_at(seed, i) = mix(seed + i * GOLDEN)
```

- **Deterministic**: Same seed + index → same color on ANY machine
- **Commutative**: XOR(a,b,c) = XOR(c,a,b) = XOR(b,c,a)
- **Associative**: XOR((a⊕b)⊕c) = XOR(a⊕(b⊕c))

This means:
1. Divide work ARBITRARILY across machines
2. Compute in ANY order
3. XOR-combine results
4. **Fingerprint MUST match** → proof of correct computation

## 2-Transducer Architecture

From Loregian's 2-transducers:

```
TRANSDUCER T: Index → Color (deterministic, pure)
MONOID M: (Color, XOR, 0)

COMPOSITION: T₁ ∘ T₂ = XOR(T₁(range₁), T₂(range₂))
```

Machines are transducers. Composition is XOR. Order doesn't matter.

## Bandwidth Results

### Single Machine (causality - M3 Max)
| Strategy | Colors/sec | SPI Verified |
|----------|-----------|--------------|
| fearless-128 | 838M | ✓ |
| fearless-256 | 813M | ✓ |
| terastream | 2.3B* | ✓ |

*Peak at 500M batch size

### Two Machines (causality + hatchery)
| Machine | Rate | Fingerprint |
|---------|------|-------------|
| causality | 838M | 0xab11046c |
| hatchery | 710M | 0xab11046c |
| **COMBINED** | **1.55B** | ✓ MATCH |

## Exo Integration

The `exe/` directory contains the exo distribution system with Gay sharding:

```python
# exe/exe/inference/mlx/gay_sharding_strategy.py

class GayShardingStrategy:
    """
    Maps model layers to devices using:
    1. Memory-weighted partitioning
    2. Triadic polarity (MINUS=attention, ERGODIC=norm, PLUS=FFN)
    3. ColorBandwidth affinity for peer selection
    """
```

### Connect via Exo

1. **Start exo on each machine**:
```bash
# causality
cd ~/ies/exe && python -m exe.main --node-id causality

# hatchery  
cd ~/ies/exe && python -m exe.main --node-id hatchery

# 2-monad
cd ~/ies/exe && python -m exe.main --node-id 2-monad
```

2. **Mesh auto-discovers** via UDP 42069 (Tailscale)

3. **Seed bundle distribution**:
```python
bundle = make_bundle(seed=7202985, total_colors=10_000_000_000, hosts=[
    "causality", "hatchery", "2-monad", ...
])
broadcast_bundle(bundle, peers)
```

## Seed Bundle Protocol

```json
{
  "seed": 7202985,
  "ranges": [
    {"host": "causality", "start": 0, "count": 500000000, "polarity": 0},
    {"host": "hatchery", "start": 500000000, "count": 500000000, "polarity": 1},
    {"host": "2-monad", "start": 1000000000, "count": 500000000, "polarity": 2}
  ],
  "total": 1500000000,
  "expected_xor": null
}
```

**Guarantees**:
- Ranges are DISJOINT by construction
- No interleaving = no network coordination during computation
- Each machine computes independently
- XOR-combine at the end

## Scaling to 34 Machines

### Expected Performance

| Machines | Est. Bandwidth | Fingerprint Verification |
|----------|---------------|-------------------------|
| 1 | 2.3B | Local |
| 2 | 4.0B | 2-way XOR |
| 3 | 5.5B | 3-way XOR |
| 10 | 15B | 10-way XOR |
| 34 | 50B+ | 34-way XOR |

### Network Topology

```
┌─────────────────────────────────────────────────────────────┐
│                    Tailscale Mesh (UDP 42069)                │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  causality ─── hatchery ─── 2-monad ─── [31 more nodes]     │
│  (coord)       (worker)     (worker)                         │
│                                                              │
│  Bundle Distribution: coordinator → all workers              │
│  Result Collection:   all workers → coordinator              │
│  Verification:        XOR all fingerprints                   │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

## Color Games

### Game 1: Furthest Color from "gay"

Find the color maximally distant from `hash("gay")`:

```python
gay_color = fnv1a("gay")  # Reference point
target = gay_color ^ 0xFFFFFFFFFFFFFFFF  # Maximum XOR distance

# Mine colors, track closest to target
best_distance = float('inf')
for i in range(n):
    c = color_at(seed, i)
    dist = bin(c ^ target).count('1')
    if dist < best_distance:
        best_distance = dist
        best_color = c
```

### Game 2: Fixed Point Hunting

Find colors where `mix(c) ≈ c`:

```python
def seek_fixed_point(seed, max_depth):
    """Hunt for short cycles in derivation chain."""
    seen = {}
    h = seed
    for d in range(max_depth):
        if h in seen:
            return (d, seen[h], h)  # Cycle found!
        seen[h] = d
        h = mix(h)
    return None
```

### Game 3: Triadic Disguise

Hide a message across 3 machines using staggered ownership:

```python
# Encode message in fingerprint differences
msg_bits = encode_message("secret")
for bit_idx, bit in enumerate(msg_bits):
    polarity = bit_idx % 3
    # Inject bit into polarity's fingerprint
    if bit:
        colors[polarity].append(special_color)
```

## Running gay.hy

```bash
# Local benchmark
uv run --with hy --with numpy --with mlx -- hy gay.hy 7202985 0 500

# Distributed (on each machine)
uv run --with hy --with numpy --with mlx -- hy gay.hy --distributed 1000 causality hatchery 2-monad
```

## Verification

All machines MUST produce matching fingerprints:

```
causality:  fp=0xab11046c  ✓
hatchery:   fp=0xab11046c  ✓
2-monad:    fp=0xab11046c  ✓

Triadic XOR: 0x4815e08adab9dcfe  ← MUST MATCH EVERYWHERE
```

If fingerprints diverge → bug, attack, or misconfiguration.

## NashProp: Zero-Message Mining

**Key insight**: With deterministic SPI, NO MESSAGES NEEDED during computation!

```
NASHPROP PROTOCOL:
1. Each machine derives range from (seed, hostname) DETERMINISTICALLY
2. No coordinator needed - everyone computes same partition
3. Mine independently with ZERO coordination
4. Only exchange fingerprints at sync points (occasional or final)
5. XOR all fingerprints → must match expected value
```

### Nash Equilibrium Properties

- **Deviation unprofitable**: Incorrect fingerprint = exclusion from consensus
- **Honest mining dominant**: Only way to produce valid fingerprint is to compute
- **Scalable**: O(1) messages per sync, O(n) computation parallelized

### Usage

```bash
# Each machine runs independently with same seed
# NashProp derives disjoint ranges from hostname hash

# causality (position 0/34)
uv run --with hy --with numpy --with mlx -- hy gay.hy --nashprop 7202985 34

# hatchery (position 1/34)  
uv run --with hy --with numpy --with mlx -- hy gay.hy --nashprop 7202985 34

# 2-monad (position 2/34)
uv run --with hy --with numpy --with mlx -- hy gay.hy --nashprop 7202985 34
```

### Theoretical Scaling

With NashProp, entire Apple Silicon population can participate:

| Machines | Combined Bandwidth | Messages/Sync |
|----------|-------------------|---------------|
| 2 | 1.7 B/sec | 2 |
| 34 | 20+ B/sec | 34 |
| 1,000 | 500+ B/sec | 1,000 |
| 1,000,000 | 500+ T/sec | 1M |

**Network overhead**: Single UDP packet per machine per sync.

## Next Steps

1. **Add more machines** to the mesh (target: 34 for 20B/sec)
2. **Optimize batch sizes** per GPU memory profile
3. **Implement color games** for mining incentives
4. **Push to 10B colors/sec** across distributed cluster
5. **Deploy NashProp** for zero-coordination mining
