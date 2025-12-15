# gay.hy - Triadic Color Bandwidth Protocol

Hylang implementation of distributed color mining with **2+ billion colors/sec** on Apple Silicon MLX.

## Quick Start

```bash
# Run benchmark (500M colors)
uv run --with hy --with numpy --with mlx -- hy gay.hy 7202985 0 500
```

## Results

| Machine | Chip | Rate | Fingerprint |
|---------|------|------|-------------|
| causality | M5 | **2.03 B/sec** | 0xab11046c ✓ |
| hatchery | M1 Ultra | **1.62 B/sec** | 0xab11046c ✓ |
| **Combined** | | **3.65 B/sec** | ✓ MATCH |

## Core Guarantees (SPI)

**Strong Parallelism Invariance**:
```
color_at(seed, i) = mix(seed + i * GOLDEN)
```

- **Deterministic**: Same seed + index → same color on ANY machine
- **Commutative**: XOR(a,b,c) = XOR(c,a,b) = XOR(b,c,a)
- **Associative**: XOR((a⊕b)⊕c) = XOR(a⊕(b⊕c))

## Architecture

```
2-TRANSDUCER COMPOSITION:
  T₁ ∘ T₂ = XOR(T₁(range₁), T₂(range₂))
  
  Split into k transducers → run ALL in parallel → XOR-compose
  SPI guarantees correctness regardless of execution order
```

## NashProp: Zero-Message Mining

Each machine derives its range from (seed, hostname) **deterministically**.
No coordinator needed - everyone computes the same partition.

```bash
# Each machine runs independently
uv run --with hy --with numpy --with mlx -- hy gay.hy 7202985 0 500
# Fingerprints MUST match across all machines
```

## See Also

- [Gay.jl](https://github.com/bmorphism/Gay.jl) - Julia implementation with Enzyme.jl autodiff
- [GAY_DISTRIBUTED_BANDWIDTH.md](./GAY_DISTRIBUTED_BANDWIDTH.md) - Full protocol documentation
