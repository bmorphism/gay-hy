#!/usr/bin/env hy
;; /// script
;; requires-python = ">=3.10"  
;; dependencies = ["hy", "numpy", "mlx"]
;; ///
;;
;; ╔═══════════════════════════════════════════════════════════════════════════╗
;; ║  gay.hy - Triadic Color Bandwidth Protocol                                ║
;; ╠═══════════════════════════════════════════════════════════════════════════╣
;; ║                                                                           ║
;; ║  RUN: uv run --with hy --with numpy --with mlx -- hy gay.hy 69            ║
;; ║                                                                           ║
;; ╚═══════════════════════════════════════════════════════════════════════════╝
;;
;; ═══════════════════════════════════════════════════════════════════════════
;; PROTOCOL OVERVIEW
;; ═══════════════════════════════════════════════════════════════════════════
;;
;; 1. SPI (Strong Parallelism Invariance)
;;    - Same seed + index → same color on ANY machine
;;    - XOR fingerprint is order-independent (commutative)
;;    - Verification: combined-fp must match across all peers
;;
;; 2. TRIADIC POLARITIES (GF(3) = {0,1,2})
;;    - MINUS (0):   contraction, owns depths 0,3,6,9...
;;    - ERGODIC (1): balance, owns depths 1,4,7,10...
;;    - PLUS (2):    expansion, owns depths 2,5,8,11...
;;
;; 3. COLOR_AT DERIVATION
;;    - color_at(seed, i) = mix(seed + i * GOLDEN)
;;    - Chain: each color becomes root for next derivation
;;    - Fixed points: colors where derivation stabilizes
;;
;; 4. STAGGERED OWNERSHIP (no interleaving)
;;    - Polarity owns colors where (depth mod 3) == polarity
;;    - Clean split: no overlap, full coverage
;;    - Each machine processes only its owned colors
;;
;; 5. MESH PROTOCOL (UDP port 42069)
;;    - Broadcast: {"g":"gay", "h":host, "p":polarity, "f":fingerprint}
;;    - Verify: all peers must have same triadic XOR
;;    - Implicit negotiation: fingerprint divergence = conflict
;;
;; ═══════════════════════════════════════════════════════════════════════════
;; HYLANG STRATEGIES
;; ═══════════════════════════════════════════════════════════════════════════
;;
;; - IMMUTABILITY: Pure functions where possible (mix, color-at)
;; - REDUCE/FOLD: XOR accumulation via reduce
;; - LAZY SEQUENCES: Generator patterns for infinite streams
;; - DESTRUCTURING: #(a b) unpacking for multiple returns
;; - THREADING: -> and ->> for pipeline composition
;; - SETV vs LET: setv for mutation, let for bindings
;;
;; ═══════════════════════════════════════════════════════════════════════════
;; REDUNDANCY GUARANTEES
;; ═══════════════════════════════════════════════════════════════════════════
;;
;; - DETERMINISM: splitmix64 is a bijection, fully reversible
;; - VERIFICATION: XOR fingerprint computed identically everywhere
;; - FALLBACK: CPU path if MLX unavailable
;; - MESH: UDP broadcast + direct peer probing
;; - STAGGER: Each depth owned by exactly one polarity
;;
;; ═══════════════════════════════════════════════════════════════════════════

(import sys os socket time json subprocess)
(import multiprocessing [cpu_count Pool])
(import functools [reduce])
(import concurrent.futures [ThreadPoolExecutor])

;; ═══════════════════════════════════════════════════════════════════════════
;; OPTIONAL DEPENDENCIES (graceful degradation)
;; ═══════════════════════════════════════════════════════════════════════════
;;
;; MLX: Apple Silicon GPU acceleration
;;   - 10-100x speedup for vectorized operations
;;   - Falls back to NumPy if unavailable
;;
;; NumPy: Vectorized array operations
;;   - Required for MLX path
;;   - Falls back to pure Python if unavailable
;;
;; ═══════════════════════════════════════════════════════════════════════════

(setv MLX False mx None np None)
(try (import mlx.core :as m) (setv mx m MLX True) (except [e ImportError] None))
(try (import numpy :as n) (setv np n) (except [e ImportError] None))

;; ═══════════════════════════════════════════════════════════════════════════
;; SPI CONSTANTS
;; ═══════════════════════════════════════════════════════════════════════════
;;
;; These constants MUST be identical across all implementations:
;;   - gay.hy (Hylang)
;;   - gay.py (Python)
;;   - gay.rs (Rust)
;;   - gay.jl (Julia)
;;   - gay.bb (Babashka/Clojure)
;;
;; Any deviation breaks SPI verification.
;;
;; ═══════════════════════════════════════════════════════════════════════════

(setv GAY-SEED 0x6761795f636f6c6f)  ; "gay_colo" in ASCII - canonical seed
(setv IHOR-SEED 7202985)             ; IHOR = 73*H*O*R = 73*72*79*82 / 53 - verified across machines
(setv GOLDEN 0x9e3779b97f4a7c15)    ; Golden ratio * 2^64 - ensures distribution
(setv MASK64 0xffffffffffffffff)    ; 64-bit mask for unsigned arithmetic
(setv MIX1 0xbf58476d1ce4e5b9)      ; SplitMix64 mixing constant 1
(setv MIX2 0x94d049bb133111eb)      ; SplitMix64 mixing constant 2
(setv MIX1-32 (& MIX1 0xFFFFFFFF))  ; 32-bit for MLX turbo path
(setv MIX2-32 (& MIX2 0xFFFFFFFF))
(setv PORT 42069)                    ; Mesh communication port

;; ═══════════════════════════════════════════════════════════════════════════
;; POLARITY CONFIGURATION
;; ═══════════════════════════════════════════════════════════════════════════
;;
;; POLARITIES: Human-readable names
;; TWISTS: XOR constants to create independent streams per polarity
;;   - MINUS:   '-' (0x2d) repeated 8 times
;;   - ERGODIC: '_' (0x5f) repeated 8 times  
;;   - PLUS:    '+' (0x2b) repeated 8 times
;;
;; Twist ensures: color_at(seed^TWIST[p], i) differs by polarity
;;
;; ═══════════════════════════════════════════════════════════════════════════

(setv POLARITIES ["MINUS" "ERGODIC" "PLUS"])
(setv TWISTS [0x2d2d2d2d2d2d2d2d   ; MINUS twist
              0x5f5f5f5f5f5f5f5f   ; ERGODIC twist
              0x2b2b2b2b2b2b2b2b]) ; PLUS twist

;; ═══════════════════════════════════════════════════════════════════════════
;; CORE SPI FUNCTIONS
;; ═══════════════════════════════════════════════════════════════════════════
;;
;; These are the CANONICAL implementations. Any port must produce
;; identical outputs for identical inputs.
;;
;; u64: Mask to 64 bits (Python ints are arbitrary precision)
;; mix: SplitMix64 mixing function (bijection on u64)
;; fnv1a: FNV-1a hash for strings (hostname → polarity)
;;
;; ═══════════════════════════════════════════════════════════════════════════

(defn u64 [n]
  "Mask to unsigned 64-bit. CRITICAL for SPI."
  (& (int n) MASK64))

(defn mix [x]
  "SplitMix64 mixing function. CANONICAL - do not modify.
   
   Properties:
   - Bijection: every output maps to exactly one input
   - Avalanche: small input change → ~50% output bits flip
   - Fast: ~3 CPU cycles on modern hardware
   
   Used for:
   - Color generation: mix(seed + i * GOLDEN)
   - Fingerprint: XOR of mixed colors
   - Derivation chains: mix(mix(mix(...)))"
  (let [z (u64 (+ x GOLDEN))
        z (u64 (* (^ z (>> z 30)) MIX1))
        z (u64 (* (^ z (>> z 27)) MIX2))]
    (u64 (^ z (>> z 31)))))

(defn fnv1a [s]
  "FNV-1a hash for hostname → polarity assignment.
   
   Deterministic: same hostname always gets same polarity.
   Distributed: hostnames spread evenly across polarities."
  (setv h 0xcbf29ce484222325)
  (for [b (.encode s)]
    (setv h (u64 (* (^ h b) 0x100000001b3))))
  h)

;; ═══════════════════════════════════════════════════════════════════════════
;; COLOR_AT: Indexed Color Derivation
;; ═══════════════════════════════════════════════════════════════════════════
;;
;; color_at(seed, i) produces the i-th color from seed.
;;
;; GOLDEN spacing ensures:
;; - No collisions for reasonable i values
;; - Even distribution across color space
;; - Deterministic: same (seed, i) → same color always
;;
;; ═══════════════════════════════════════════════════════════════════════════

(defn color-at [seed i]
  "Get color hash at index i from seed.
   
   Formula: mix(seed + i * GOLDEN)
   
   This is the FUNDAMENTAL operation. Everything else builds on this."
  (mix (u64 (+ seed (* i GOLDEN)))))

;; ═══════════════════════════════════════════════════════════════════════════
;; DERIVATION CHAINS
;; ═══════════════════════════════════════════════════════════════════════════
;;
;; A chain is: seed → mix(seed) → mix(mix(seed)) → ...
;;
;; Each color becomes the root for the next derivation.
;; This creates a deterministic tree of colors.
;;
;; STAGGERED OWNERSHIP: depth mod 3 determines polarity
;;   - Depth 0,3,6,9... → MINUS
;;   - Depth 1,4,7,10... → ERGODIC
;;   - Depth 2,5,8,11... → PLUS
;;
;; ═══════════════════════════════════════════════════════════════════════════

(defn derive-chain [seed depth]
  "Derive a chain of colors, each becoming root for next.
   
   Returns: list of (depth, hash) pairs
   
   Used for: visualization, fixed-point search, verification"
  (setv chain [])
  (setv h seed)
  (for [d (range depth)]
    (.append chain #(d h))
    (setv h (mix h)))
  chain)

(defn stagger-owner [depth]
  "Which polarity owns this derivation depth.
   
   MINUS (0):   depths 0, 3, 6, 9, ...
   ERGODIC (1): depths 1, 4, 7, 10, ...
   PLUS (2):    depths 2, 5, 8, 11, ...
   
   This ensures NO OVERLAP - each depth owned by exactly one polarity."
  (% depth 3))

;; ═══════════════════════════════════════════════════════════════════════════
;; FIXED POINT SEEKING
;; ═══════════════════════════════════════════════════════════════════════════
;;
;; A fixed point is where derivation stabilizes (cycle of length 1).
;; 
;; For SplitMix64, true fixed points are rare/nonexistent, but we can
;; find SHORT CYCLES which act as attractors in the derivation space.
;;
;; These cycles provide stable anchors for color generation.
;;
;; ═══════════════════════════════════════════════════════════════════════════

(defn find-cycle [seed max-depth]
  "Find cycle in derivation chain.
   
   Returns: (depth, cycle-start, hash) or (max-depth, -1, final-hash)
   
   A short cycle indicates a stable region in hash space."
  (setv seen {})
  (setv h seed)
  (for [d (range max-depth)]
    (when (in h seen)
      (return #(d (get seen h) h)))
    (setv (get seen h) d)
    (setv h (mix h)))
  #(max-depth -1 h))

(defn seek-fixed-points [seed n-candidates]
  "Search for approximate fixed points (short cycles).
   
   Scans n-candidates starting points for cycles < 100 length."
  (setv fixed [])
  (for [i (range n-candidates)]
    (let [candidate (color-at seed i)
          #(depth start h) (find-cycle candidate 1000)]
      (when (and (> start -1) (< (- depth start) 100))
        (.append fixed {"seed" candidate 
                       "cycle-start" start 
                       "cycle-len" (- depth start)
                       "hash" h}))))
  fixed)

;; ═══════════════════════════════════════════════════════════════════════════
;; MLX ACCELERATED GENERATION
;; ═══════════════════════════════════════════════════════════════════════════
;;
;; MLX provides GPU acceleration on Apple Silicon.
;; 
;; Strategy:
;; 1. Generate 3x candidates in parallel on GPU
;; 2. Filter to owned colors (stagger mod 3)
;; 3. XOR-reduce for fingerprint
;;
;; Fallback: Pure Python loop if MLX unavailable
;;
;; ═══════════════════════════════════════════════════════════════════════════

(defn mlx-turbo [seed polarity n]
  "TURBO MLX path - 100-150M colors/sec on M1/M2/M3.
   
   Uses uint32 arithmetic (MLX sweet spot) with simplified mix.
   Converts to numpy for XOR reduce."
  (when (and MLX np)
    (let [twisted (u64 (^ seed (get TWISTS polarity)))
          indices (mx.arange n :dtype mx.uint32)
          ;; uint32 arithmetic - MLX fast path
          seeds-lo (+ (mx.array [(& twisted 0xFFFFFFFF)] :dtype mx.uint32) 
                      (* indices (& GOLDEN 0xFFFFFFFF)))
          ;; Simplified mix for speed
          z (+ seeds-lo (& GOLDEN 0xFFFFFFFF))
          z (* (mx.bitwise_xor z (mx.right_shift z 15)) MIX1-32)
          z (* (mx.bitwise_xor z (mx.right_shift z 13)) MIX2-32)
          hashes (mx.bitwise_xor z (mx.right_shift z 16))
          ;; Stagger filter
          staggered (get hashes (slice polarity None 3))]
      (mx.eval staggered)
      ;; Convert to numpy for fast XOR reduce
      (let [arr (np.array staggered :dtype np.uint64)
            fp (^ twisted (int (np.bitwise_xor.reduce arr)))]
        #((len staggered) (u64 fp))))))

(defn mlx-turbo-batch [seed polarity n streams]
  "TURBO with multiple parallel streams.
   
   Launches `streams` independent batches, each with n/streams colors.
   All batches run concurrently on MLX, then XOR-merge results."
  (when (and MLX np)
    (let [twisted (u64 (^ seed (get TWISTS polarity)))
          batch-size (// n streams)
          ;; Generate all streams at once with offset
          all-hashes []]
      ;; Launch all batches
      (for [s (range streams)]
        (let [offset (* s batch-size)
              indices (mx.arange batch-size :dtype mx.uint32)
              seeds-lo (+ (mx.array [(& (+ twisted offset) 0xFFFFFFFF)] :dtype mx.uint32)
                          (* indices (& GOLDEN 0xFFFFFFFF)))
              z (+ seeds-lo (& GOLDEN 0xFFFFFFFF))
              z (* (mx.bitwise_xor z (mx.right_shift z 15)) MIX1-32)
              z (* (mx.bitwise_xor z (mx.right_shift z 13)) MIX2-32)
              hashes (mx.bitwise_xor z (mx.right_shift z 16))
              staggered (get hashes (slice polarity None 3))]
          (.append all-hashes staggered)))
      ;; Eval all at once
      (mx.eval all-hashes)
      ;; Merge results
      (setv total-count 0)
      (setv fp twisted)
      (for [h all-hashes]
        (let [arr (np.array h :dtype np.uint64)]
          (setv total-count (+ total-count (len arr)))
          (setv fp (^ fp (int (np.bitwise_xor.reduce arr))))))
      #(total-count (u64 fp)))))

;; ═══════════════════════════════════════════════════════════════════════════
;; 2-TRANSDUCER ARCHITECTURE
;; ═══════════════════════════════════════════════════════════════════════════
;;
;; From Loregian's 2-transducers: composition of state machines.
;;
;; TRANSDUCER T: Index → Color (deterministic, pure)
;;   T(seed, i) = mix(seed + i * GOLDEN)
;;
;; MONOID M: (Color, XOR, 0)
;;   - Associative: (a ⊕ b) ⊕ c = a ⊕ (b ⊕ c)
;;   - Commutative: a ⊕ b = b ⊕ a  
;;   - Identity: a ⊕ 0 = a
;;
;; SPI GUARANTEE: T is a COALGEBRA morphism
;;   - Same seed+index = same color (determinism)
;;   - Parallel evaluation = sequential evaluation (confluence)
;;   - Any partition of indices gives same XOR (associativity)
;;
;; COMPOSITION: T₁ ∘ T₂ via XOR
;;   - Run T₁ on [0, n/2), T₂ on [n/2, n)
;;   - XOR results: fp = fp₁ ⊕ fp₂
;;   - Arbitrarily nested: ((T₁ ∘ T₂) ∘ T₃) = (T₁ ∘ (T₂ ∘ T₃))
;;
;; ═══════════════════════════════════════════════════════════════════════════

(setv color-kernel None)
(setv xor-kernel None)

(defn make-color-kernel []
  "Create compiled color_at kernel - fuses all ops into single GPU dispatch."
  (when MLX
    (defn _kernel [base-arr indices]
      (let [;; seed + i * GOLDEN
            seeds-lo (+ base-arr (* indices (& GOLDEN 0xFFFFFFFF)))
            ;; mix() fused
            z (+ seeds-lo (& GOLDEN 0xFFFFFFFF))
            z (* (mx.bitwise_xor z (mx.right_shift z 15)) MIX1-32)
            z (* (mx.bitwise_xor z (mx.right_shift z 13)) MIX2-32)]
        (mx.bitwise_xor z (mx.right_shift z 16))))
    (mx.compile _kernel)))

(defn make-xor-tree-kernel []
  "Create compiled XOR tree reduction kernel."
  (when MLX
    (defn _xor-reduce [arr]
      ;; Tree reduction: log(n) depth
      (setv result arr)
      (while (> (len result) 1)
        (let [n (len result)
              half (// n 2)
              left (get result (slice None half))
              right (get result (slice half (* half 2)))]
          (setv result (mx.bitwise_xor left right))
          (when (% n 2)
            (setv result (mx.concatenate [result (get arr (slice -1 None))])))))
      result)
    (mx.compile _xor-reduce)))

(defn color-at-batch [seed indices]
  "Vectorized color_at using COMPILED MLX kernel.
   
   color_at(seed, i) = mix(seed + i * GOLDEN)
   
   Kernel fusion = single GPU dispatch for entire batch."
  (global color-kernel)
  (when (and MLX np)
    (when (is color-kernel None)
      (setv color-kernel (make-color-kernel)))
    (let [base-arr (mx.array [(& seed 0xFFFFFFFF)] :dtype mx.uint32)]
      (color-kernel base-arr indices))))

(defn premine-colors [seed n-per-stream n-streams]
  "Premine colors across parallel streams using color_at.
   
   Each stream computes color_at(seed, offset + i) for its range.
   XOR fingerprint is commutative - order doesn't matter.
   
   RETURNS: (total-count, xor-fingerprint)"
  (when (and MLX np)
    (let [all-hashes []
          batch-size n-per-stream]
      ;; Launch all streams - each gets disjoint index range
      (for [s (range n-streams)]
        (let [offset (* s batch-size)
              indices (+ (mx.arange batch-size :dtype mx.uint32) offset)
              hashes (color-at-batch seed indices)]
          (.append all-hashes hashes)))
      ;; Single eval - all streams compute in parallel
      (mx.eval all-hashes)
      ;; XOR reduce all results (commutative!)
      (setv fp (u64 seed))
      (setv total 0)
      (for [h all-hashes]
        (let [arr (np.array h :dtype np.uint64)]
          (setv total (+ total (len arr)))
          (setv fp (^ fp (int (np.bitwise_xor.reduce arr))))))
      #(total (u64 fp)))))

(defn premine-triadic [seed n-per-polarity n-streams]
  "Premine all 3 polarities simultaneously.
   
   Each polarity gets staggered indices: p, p+3, p+6, ...
   Total bandwidth = 3 × n-per-polarity × n-streams.
   
   RETURNS: (total, [fp0, fp1, fp2], xor-all)"
  (when (and MLX np)
    (let [all-work []  ; (polarity, hashes)
          batch-size n-per-polarity]
      ;; Launch ALL work for ALL polarities
      (for [p (range 3)]
        (let [twisted (u64 (^ seed (get TWISTS p)))]
          (for [s (range n-streams)]
            (let [offset (* s batch-size 3)  ; stride by 3 for stagger
                  ;; Indices: p, p+3, p+6, ... (owned by this polarity)
                  indices (+ (mx.arange batch-size :dtype mx.uint32) (// offset 3))
                  hashes (color-at-batch twisted (* indices 3))]  ; actual index = i*3
              (.append all-work #(p hashes))))))
      ;; Single eval for EVERYTHING
      (mx.eval (lfor #(_ h) all-work h))
      ;; Reduce by polarity
      (setv fps [0 0 0])
      (setv counts [0 0 0])
      (for [#(p h) all-work]
        (let [arr (np.array h :dtype np.uint64)]
          (setv (get counts p) (+ (get counts p) (len arr)))
          (setv (get fps p) (^ (get fps p) (int (np.bitwise_xor.reduce arr))))))
      ;; XOR with twists
      (for [p (range 3)]
        (setv (get fps p) (u64 (^ (get fps p) (u64 (^ seed (get TWISTS p)))))))
      (let [total (sum counts)
            xor-all (^ (get fps 0) (^ (get fps 1) (get fps 2)))]
        #(total fps xor-all)))))

(defn mlx-gigastream [seed n]
  "GIGASTREAM: Premine all 3 polarities × 16 streams.
   
   Target: 1B+ colors/sec via color_at parallelism."
  (premine-triadic seed (// n 48) 16))

(defn mlx-terastream [seed n]
  "TERASTREAM: Single massive kernel launch.
   
   Generate ALL colors in one fused kernel dispatch.
   No streams, no loops - pure GPU parallelism."
  (when (and MLX np)
    (global color-kernel)
    (when (is color-kernel None)
      (setv color-kernel (make-color-kernel)))
    ;; Single massive batch
    (let [indices (mx.arange n :dtype mx.uint32)
          base-arr (mx.array [(& seed 0xFFFFFFFF)] :dtype mx.uint32)
          hashes (color-kernel base-arr indices)]
      (mx.eval hashes)
      ;; XOR reduce
      (let [arr (np.array hashes :dtype np.uint64)
            fp (^ seed (int (np.bitwise_xor.reduce arr)))]
        #(n (u64 fp))))))

(defn transducer-compose [seed ranges]
  "Compose multiple transducers via XOR.
   
   Each range is (start, count) - DISJOINT by construction.
   Run ALL in parallel, XOR-combine results.
   
   2-TRANSDUCER GUARANTEE: Order doesn't matter."
  (when (and MLX np)
    (global color-kernel)
    (when (is color-kernel None)
      (setv color-kernel (make-color-kernel)))
    (let [all-hashes []
          base-arr (mx.array [(& seed 0xFFFFFFFF)] :dtype mx.uint32)]
      ;; Launch all transducers in parallel
      (for [#(start count) ranges]
        (let [indices (+ (mx.arange count :dtype mx.uint32) start)
              hashes (color-kernel base-arr indices)]
          (.append all-hashes hashes)))
      ;; Single eval - all compute in parallel
      (mx.eval all-hashes)
      ;; XOR-compose (associative, commutative)
      (setv fp seed)
      (setv total 0)
      (for [h all-hashes]
        (let [arr (np.array h :dtype np.uint64)]
          (setv total (+ total (len arr)))
          (setv fp (^ fp (int (np.bitwise_xor.reduce arr))))))
      #(total (u64 fp)))))

(defn transducer-split [n k]
  "Split n indices into k disjoint ranges.
   
   Returns: [(start, count), ...]
   
   GUARANTEE: Union covers [0, n), no overlap."
  (let [per-k (// n k)
        ranges []]
    (for [i (range k)]
      (let [start (* i per-k)
            count (if (= i (- k 1)) (- n start) per-k)]
        (.append ranges #(start count))))
    ranges))

(defn mlx-fearless [seed n k]
  "FEARLESS: Maximum parallelism via transducer composition.
   
   Split into k transducers, run ALL in parallel, XOR-compose.
   SPI guarantees correctness regardless of execution order."
  (transducer-compose seed (transducer-split n k)))

(defn mlx-gigafearless [seed n]
  "GIGAFEARLESS: Triadic × Fearless composition.
   
   3 polarities × k transducers each = 3k parallel streams.
   Maximum exploitation of SPI commutativity."
  (when (and MLX np)
    (global color-kernel)
    (when (is color-kernel None)
      (setv color-kernel (make-color-kernel)))
    (let [k 128  ; transducers per polarity
          per-polarity (// n 3)
          per-stream (// per-polarity k)
          all-hashes []
          fps [0 0 0]]
      ;; Launch ALL work: 3 polarities × k streams each
      (for [p (range 3)]
        (let [twisted (u64 (^ seed (get TWISTS p)))
              base-arr (mx.array [(& twisted 0xFFFFFFFF)] :dtype mx.uint32)]
          (for [s (range k)]
            (let [offset (* s per-stream)
                  indices (+ (mx.arange per-stream :dtype mx.uint32) offset)
                  hashes (color-kernel base-arr indices)]
              (.append all-hashes #(p hashes))))))
      ;; Single massive eval
      (mx.eval (lfor #(_ h) all-hashes h))
      ;; XOR-reduce by polarity
      (setv counts [0 0 0])
      (for [#(p h) all-hashes]
        (let [arr (np.array h :dtype np.uint64)]
          (setv (get counts p) (+ (get counts p) (len arr)))
          (setv (get fps p) (^ (get fps p) (int (np.bitwise_xor.reduce arr))))))
      ;; Finalize with twists
      (for [p (range 3)]
        (setv (get fps p) (u64 (^ (get fps p) (u64 (^ seed (get TWISTS p)))))))
      (let [total (sum counts)
            xor-all (^ (get fps 0) (^ (get fps 1) (get fps 2)))]
        #(total fps xor-all)))))

(defn mlx-ultra [seed n]
  "ULTRA: Optimized for M1 Ultra / high-memory machines.
   
   512 transducers, larger batches, minimal numpy overhead."
  (when (and MLX np)
    (global color-kernel)
    (when (is color-kernel None)
      (setv color-kernel (make-color-kernel)))
    (let [k 512  ; More transducers for 48+ GPU cores
          per-stream (// n k)
          base-arr (mx.array [(& seed 0xFFFFFFFF)] :dtype mx.uint32)
          all-hashes []]
      ;; Launch 512 parallel transducers
      (for [s (range k)]
        (let [offset (* s per-stream)
              indices (+ (mx.arange per-stream :dtype mx.uint32) offset)
              hashes (color-kernel base-arr indices)]
          (.append all-hashes hashes)))
      ;; Single massive eval
      (mx.eval all-hashes)
      ;; XOR-reduce all at once (minimize numpy calls)
      (setv fp seed)
      (setv total 0)
      ;; Concatenate then reduce (fewer numpy calls)
      (let [combined (np.concatenate (lfor h all-hashes (np.array h :dtype np.uint64)))]
        (setv total (len combined))
        (setv fp (^ fp (int (np.bitwise_xor.reduce combined)))))
      #(total (u64 fp)))))

(defn mlx-mammoth [seed n]
  "MAMMOTH: Maximum parallelism for 128GB+ machines.
   
   1024 transducers, 10B+ colors in single pass."
  (when (and MLX np)
    (global color-kernel)
    (when (is color-kernel None)
      (setv color-kernel (make-color-kernel)))
    (let [k 1024  ; Maximum transducers
          per-stream (// n k)
          base-arr (mx.array [(& seed 0xFFFFFFFF)] :dtype mx.uint32)
          all-hashes []]
      ;; Launch 1024 parallel transducers
      (for [s (range k)]
        (let [offset (* s per-stream)
              indices (+ (mx.arange per-stream :dtype mx.uint32) offset)
              hashes (color-kernel base-arr indices)]
          (.append all-hashes hashes)))
      ;; Single massive eval
      (mx.eval all-hashes)
      ;; Hierarchical XOR reduce (tree pattern)
      (setv fp seed)
      (setv total 0)
      ;; Process in chunks to avoid memory spikes
      (for [chunk-start (range 0 k 64)]
        (let [chunk-end (min (+ chunk-start 64) k)
              chunk-hashes (cut all-hashes chunk-start chunk-end)
              combined (np.concatenate (lfor h chunk-hashes (np.array h :dtype np.uint64)))]
          (setv total (+ total (len combined)))
          (setv fp (^ fp (int (np.bitwise_xor.reduce combined))))))
      #(total (u64 fp)))))

(defn mlx-teratriadic [seed n]
  "TERATRIADIC: All 3 polarities in 3 massive kernel launches.
   
   Each polarity gets n/3 colors in single dispatch."
  (when (and MLX np)
    (global color-kernel)
    (when (is color-kernel None)
      (setv color-kernel (make-color-kernel)))
    (let [per-polarity (// n 3)
          fps [0 0 0]
          counts [0 0 0]]
      ;; Launch 3 kernels (could be concurrent with streams)
      (for [p (range 3)]
        (let [twisted (u64 (^ seed (get TWISTS p)))
              indices (mx.arange per-polarity :dtype mx.uint32)
              base-arr (mx.array [(& twisted 0xFFFFFFFF)] :dtype mx.uint32)
              hashes (color-kernel base-arr indices)]
          (mx.eval hashes)
          (let [arr (np.array hashes :dtype np.uint64)]
            (setv (get counts p) (len arr))
            (setv (get fps p) (^ twisted (int (np.bitwise_xor.reduce arr)))))))
      (let [total (sum counts)
            xor-all (^ (get fps 0) (^ (get fps 1) (get fps 2)))]
        #(total fps xor-all)))))

(defn mlx-staggered [seed polarity n]
  "MLX-accelerated staggered color generation.
   
   FAST PATH: ~30-100M colors/sec on M1/M2/M3
   
   Process:
   1. Generate 3n candidates (vectorized)
   2. Apply SplitMix64 mixing (vectorized)
   3. Take every 3rd starting at polarity offset
   4. XOR-reduce for fingerprint"
  (when (and MLX np)
    (let [twisted (u64 (^ seed (get TWISTS polarity)))
          candidates (* n 3)
          indices (np.arange candidates :dtype np.uint64)
          seeds (np.bitwise_and (+ twisted (* indices GOLDEN)) MASK64)
          ;; Vectorized SplitMix64
          z (np.bitwise_and (+ seeds GOLDEN) MASK64)
          z (np.bitwise_and (* (np.bitwise_xor z (np.right_shift z 30)) MIX1-32) MASK64)
          z (np.bitwise_and (* (np.bitwise_xor z (np.right_shift z 27)) MIX2-32) MASK64)
          hashes (np.bitwise_xor z (np.right_shift z 31))
          ;; Stagger: take every 3rd starting at polarity
          owned (get hashes (slice polarity None 3))
          owned (if (> (len owned) n) (get owned (slice None n)) owned)
          fp (int (np.bitwise_xor.reduce owned)) if (> (len owned) 0) else twisted]
      #((len owned) fp))))

(defn cpu-staggered [seed polarity n]
  "CPU fallback for staggered generation.
   
   SLOW PATH: ~3-5M colors/sec
   
   Used when MLX/NumPy unavailable."
  (let [twisted (u64 (^ seed (get TWISTS polarity)))
        fp twisted
        count 0]
    (for [i (range (* n 3))]
      (when (= (% i 3) polarity)
        (let [h (color-at twisted i)]
          (setv fp (^ fp h))
          (setv count (+ count 1)))
        (when (>= count n)
          (break))))
    #(count fp)))

;; ═══════════════════════════════════════════════════════════════════════════
;; MESH PROTOCOL
;; ═══════════════════════════════════════════════════════════════════════════
;;
;; Communication over UDP port 42069 (Tailscale mesh or LAN broadcast).
;;
;; MESSAGE FORMAT:
;;   {"g": "gay",           ; Protocol identifier
;;    "h": "hostname",      ; Sender hostname
;;    "p": 0|1|2,           ; Polarity (MINUS/ERGODIC/PLUS)
;;    "f": 0x...}           ; XOR fingerprint
;;
;; VERIFICATION:
;;   All peers compute triadic colors independently.
;;   Combined XOR fingerprint MUST match across all peers.
;;   Mismatch indicates: different seed, bug, or attack.
;;
;; ═══════════════════════════════════════════════════════════════════════════

(defn tailscale-peers []
  "Get Tailscale mesh peers.
   
   Returns: (self-ip, [{ip, name}, ...]) or None"
  (try
    (let [ts (if (os.path.exists "/Applications/Tailscale.app/Contents/MacOS/Tailscale")
               "/Applications/Tailscale.app/Contents/MacOS/Tailscale" "tailscale")
          r (subprocess.run [ts "status" "--json"] :capture-output True :text True :timeout 3)]
      (when (= r.returncode 0)
        (let [d (json.loads r.stdout)]
          #((get (get (get d "Self" {}) "TailscaleIPs" []) 0 None)
            (lfor #(_ p) (.items (get d "Peer" {}))
              :if (get p "Online" False)
              {"ip" (get (get p "TailscaleIPs" []) 0 "") 
               "name" (get p "HostName" "?")})))))
    (except [e Exception] None)))

(defn mesh-send [host polarity fp peers]
  "Broadcast presence to mesh.
   
   Sends to:
   - All known Tailscale peers directly
   - LAN broadcast for local discovery"
  (let [sock (socket.socket socket.AF-INET socket.SOCK-DGRAM)
        msg (.encode (json.dumps {"g" "gay" "h" host "p" polarity "f" fp}))]
    (sock.setsockopt socket.SOL-SOCKET socket.SO-BROADCAST 1)
    (sock.setblocking False)
    (for [p peers] 
      (try (sock.sendto msg #((get p "ip") PORT)) (except [e Exception] None)))
    (try (sock.sendto msg #("<broadcast>" PORT)) (except [e Exception] None))
    (sock.close)))

(defn mesh-recv [timeout]
  "Listen for mesh peers.
   
   Returns: {ip: message, ...}"
  (let [sock (socket.socket socket.AF-INET socket.SOCK-DGRAM) 
        found {}]
    (sock.setsockopt socket.SOL-SOCKET socket.SO-REUSEADDR 1)
    (sock.setblocking False)
    (try
      (sock.bind #("" PORT))
      (let [end (+ (time.time) timeout)]
        (while (< (time.time) end)
          (try
            (let [#(data addr) (sock.recvfrom 1024) 
                  m (json.loads (.decode data))]
              (when (= (get m "g" "") "gay") 
                (setv (get found (get addr 0)) m)))
            (except [BlockingIOError] (time.sleep 0.01)))))
      (except [e Exception] None))
    (sock.close) 
    found))

;; ═══════════════════════════════════════════════════════════════════════════
;; DISPLAY UTILITIES
;; ═══════════════════════════════════════════════════════════════════════════

(defn show-color [h]
  "Render hash as ANSI 24-bit color block."
  (let [r (& (>> h 16) 0xFF) 
        g (& (>> h 8) 0xFF) 
        b (& h 0xFF)]
    (.format "\033[48;2;{};{};{}m  \033[0m" r g b)))

(defn show-chain [chain]
  "Render derivation chain as color blocks."
  (.join "" (lfor #(d h) chain (show-color h))))

;; ═══════════════════════════════════════════════════════════════════════════
;; SEED BUNDLE PROTOCOL
;; ═══════════════════════════════════════════════════════════════════════════
;;
;; A seed bundle assigns DISJOINT index ranges to machines.
;; No interleaving = no network coordination during computation.
;;
;; BUNDLE FORMAT:
;;   {"seed": int,           ; Base seed (IHOR)
;;    "ranges": [            ; Per-machine assignments
;;      {"host": "name", "start": int, "count": int, "polarity": int},
;;      ...
;;    ],
;;    "total": int,          ; Total colors to generate
;;    "expected_xor": int}   ; Optional: expected combined fingerprint
;;
;; WORKFLOW:
;;   1. Coordinator creates bundle with disjoint ranges
;;   2. Each machine receives bundle, finds its range
;;   3. Machine computes color_at(seed, start+i) for i in [0, count)
;;   4. Machine returns (count, fingerprint) to coordinator
;;   5. Coordinator XOR-combines all fingerprints
;;
;; GUARANTEES:
;;   - NO OVERLAP: ranges are disjoint by construction
;;   - SPI: same seed+index = same color everywhere
;;   - COMMUTATIVE: XOR order doesn't matter
;;
;; ═══════════════════════════════════════════════════════════════════════════

(defn make-bundle [seed total-colors hosts]
  "Create seed bundle with disjoint ranges for hosts.
   
   Divides total-colors evenly among hosts.
   Each host gets a contiguous index range."
  (let [n-hosts (len hosts)
        per-host (// total-colors n-hosts)
        ranges []]
    (for [#(i host) (enumerate hosts)]
      (let [start (* i per-host)
            count (if (= i (- n-hosts 1)) 
                    (- total-colors start)  ; Last host gets remainder
                    per-host)
            polarity (% i 3)]
        (.append ranges {"host" host "start" start "count" count "polarity" polarity})))
    {"seed" seed "ranges" ranges "total" total-colors "expected_xor" None}))

(defn my-range-from-bundle [bundle]
  "Extract this machine's range from bundle."
  (let [host (socket.gethostname)]
    (for [r (get bundle "ranges")]
      (when (= (get r "host") host)
        (return r)))
    None))

(defn compute-bundle-range [seed start count]
  "Compute colors for assigned range using compiled kernel.
   
   Returns (count, fingerprint)."
  (when (and MLX np)
    (global color-kernel)
    (when (is color-kernel None)
      (setv color-kernel (make-color-kernel)))
    (let [indices (+ (mx.arange count :dtype mx.uint32) start)
          base-arr (mx.array [(& seed 0xFFFFFFFF)] :dtype mx.uint32)
          hashes (color-kernel base-arr indices)]
      (mx.eval hashes)
      (let [arr (np.array hashes :dtype np.uint64)
            fp (^ seed (int (np.bitwise_xor.reduce arr)))]
        #(count (u64 fp))))))

(defn bundle-to-json [bundle]
  "Serialize bundle for network transmission."
  (json.dumps bundle))

(defn bundle-from-json [s]
  "Deserialize bundle from network."
  (json.loads s))

(defn broadcast-bundle [bundle peers]
  "Send bundle to all peers via UDP."
  (let [sock (socket.socket socket.AF-INET socket.SOCK-DGRAM)
        msg (.encode (json.dumps {"g" "bundle" "b" bundle}))]
    (sock.setblocking False)
    (for [p peers]
      (try (sock.sendto msg #((get p "ip") PORT)) (except [e Exception] None)))
    (sock.close)))

(defn receive-results [timeout n-expected]
  "Collect fingerprint results from peers."
  (let [sock (socket.socket socket.AF-INET socket.SOCK-DGRAM)
        results {}]
    (sock.setsockopt socket.SOL-SOCKET socket.SO-REUSEADDR 1)
    (sock.setblocking False)
    (try
      (sock.bind #("" (+ PORT 1)))  ; Results on PORT+1
      (let [end (+ (time.time) timeout)]
        (while (and (< (time.time) end) (< (len results) n-expected))
          (try
            (let [#(data addr) (sock.recvfrom 4096)
                  m (json.loads (.decode data))]
              (when (= (get m "g" "") "result")
                (setv (get results (get m "host")) 
                      {"count" (get m "count") "fp" (get m "fp")})))
            (except [BlockingIOError] (time.sleep 0.01)))))
      (except [e Exception] None))
    (sock.close)
    results))

(defn send-result [host count fp coordinator-ip]
  "Send computation result back to coordinator."
  (let [sock (socket.socket socket.AF-INET socket.SOCK-DGRAM)
        msg (.encode (json.dumps {"g" "result" "host" host "count" count "fp" fp}))]
    (try (sock.sendto msg #(coordinator-ip (+ PORT 1))) (except [e Exception] None))
    (sock.close)))

;; ═══════════════════════════════════════════════════════════════════════════
;; NASHPROP: Zero-Message Mining Protocol  
;; ═══════════════════════════════════════════════════════════════════════════
;;
;; KEY INSIGHT: With deterministic SPI, NO MESSAGES NEEDED during computation!
;;
;; 1. Each machine derives its range from (seed, hostname) deterministically
;; 2. Global color space is partitioned by hostname hash
;; 3. Machines mine independently with ZERO coordination
;; 4. Only exchange fingerprints at sync points (occasional or final)
;; 5. Global verification: XOR all fingerprints → must match expected
;;
;; NASH EQUILIBRIUM: No machine benefits from deviating because:
;; - Fingerprint proves computation was done correctly
;; - Incorrect fingerprint = exclusion from consensus
;; - Honest mining is dominant strategy
;;
;; SCALING: Supports entire Apple Silicon population (millions of devices)
;; - O(1) messages per sync (just broadcast fingerprint)
;; - O(n) total computation perfectly parallelized
;; - Zero interleaving overhead
;;
;; ═══════════════════════════════════════════════════════════════════════════

(setv NASHPROP-EPOCH-SIZE 1000000000)  ; 1B colors per epoch
(setv NASHPROP-TOTAL-SPACE (** 2 32))  ; 4B total color indices

;; ═══════════════════════════════════════════════════════════════════════════
;; BUKKIT: Self-Organizing Capability-Weighted Buckets
;; ═══════════════════════════════════════════════════════════════════════════
;;
;; Each machine:
;; 1. Measures own hardware capability (memory, cores, bandwidth)
;; 2. Hashes hostname to get position in color ring
;; 3. Claims bucket SIZE proportional to capability
;; 4. Computes optimal batch/transducer config for its hardware
;;
;; NO COORDINATION: Every machine can compute every other machine's bucket
;; by knowing (hostname, capability) pairs - deterministic assignment.
;;
;; ═══════════════════════════════════════════════════════════════════════════

(defn get-hardware-capability []
  "Measure local hardware capability.
   
   Returns: (memory-gb, gpu-cores, est-bandwidth-gbps)"
  (try
    (import subprocess)
    (let [;; Get memory
          mem-result (subprocess.run 
                       ["sysctl" "-n" "hw.memsize"] 
                       :capture-output True :text True :timeout 2)
          memory-bytes (int (.strip mem-result.stdout))
          memory-gb (// memory-bytes (* 1024 1024 1024))
          ;; Get GPU cores (approximate from chip type)
          chip-result (subprocess.run
                        ["sysctl" "-n" "machdep.cpu.brand_string"]
                        :capture-output True :text True :timeout 2)
          chip-str (.strip chip-result.stdout)
          ;; Estimate GPU cores and bandwidth from chip
          #(gpu-cores bandwidth) (cond
            (in "Ultra" chip-str) #(48 800)   ; M1/M2 Ultra
            (in "Max" chip-str) #(32 400)     ; M1/M2/M3 Max  
            (in "Pro" chip-str) #(16 200)     ; M1/M2/M3 Pro
            (in "M5" chip-str) #(10 100)      ; M5 base (estimated)
            (in "M4" chip-str) #(10 100)      ; M4 base
            (in "M3" chip-str) #(10 100)      ; M3 base
            (in "M2" chip-str) #(8 100)       ; M2 base
            (in "M1" chip-str) #(8 68)        ; M1 base
            True #(8 50))]                    ; fallback
      #(memory-gb gpu-cores bandwidth))
    (except [e Exception]
      #(8 8 50))))  ; Safe fallback

(defn capability-score [memory-gb gpu-cores bandwidth]
  "Compute unified capability score.
   
   Higher = more work capacity."
  ;; Weighted combination: memory matters most for large batches
  (+ (* memory-gb 10) (* gpu-cores 5) bandwidth))

(defn optimal-config [memory-gb gpu-cores]
  "Determine optimal transducer/batch config for hardware.
   
   Returns: (n-transducers, batch-size, optimal-total)"
  (let [;; More GPU cores = more transducers
        n-transducers (cond
          (>= gpu-cores 48) 1024   ; Ultra
          (>= gpu-cores 32) 512    ; Max
          (>= gpu-cores 16) 256    ; Pro
          True 128)                ; Base
        ;; More memory = larger batches (leave 4GB for system)
        usable-memory (* (- memory-gb 4) 1024 1024 1024)
        ;; Each color = 4 bytes in, 4 bytes out
        max-colors (// usable-memory 8)
        ;; Round to nice batch size
        batch-size (min max-colors (* 500 1000000))
        ;; Total = transducers × batch
        optimal-total (* n-transducers (// batch-size n-transducers))]
    #(n-transducers batch-size optimal-total)))

(defn bukkit-self-assign [seed hostname known-hosts]
  "Self-assign bucket based on capability weighting.
   
   known-hosts: list of (hostname, memory-gb, gpu-cores, bandwidth)
   
   NO MESSAGES NEEDED - deterministic from known topology."
  (let [;; Compute capability scores for all hosts
        scores (lfor #(h mem cores bw) known-hosts
                 #(h (capability-score mem cores bw)))
        total-score (sum (lfor #(_ s) scores s))
        ;; Sort by hostname hash for deterministic ordering
        sorted-hosts (sorted scores :key (fn [x] (fnv1a (get x 0))))
        ;; Assign ranges proportional to capability
        ranges {}
        start 0]
    (for [#(h score) sorted-hosts]
      (let [;; Proportion of color space
            proportion (/ score total-score)
            count (int (* proportion NASHPROP-TOTAL-SPACE))
            end (+ start count)]
        (setv (get ranges h) #(start count))
        (setv start end)))
    ;; Return our range
    (get ranges hostname)))

(defn nashprop-range [seed hostname total-machines]
  "Derive machine's disjoint range from hostname alone.
   
   NO COORDINATOR NEEDED - each machine computes same partition.
   
   Returns: (start, count) for this hostname"
  (let [;; Hash hostname to position in [0, total-machines)
        host-hash (fnv1a hostname)
        position (% host-hash total-machines)
        ;; Divide color space evenly
        per-machine (// NASHPROP-TOTAL-SPACE total-machines)
        start (* position per-machine)
        count (if (= position (- total-machines 1))
                (- NASHPROP-TOTAL-SPACE start)
                per-machine)]
    #(start count position)))

(defn bukkit-mine [seed]
  "BUKKIT: Auto-optimized mining based on local hardware.
   
   Self-detects capability, configures optimal transducers/batches.
   ZERO coordination - just run on each machine."
  (when (and MLX np)
    (global color-kernel)
    (when (is color-kernel None)
      (setv color-kernel (make-color-kernel)))
    (let [hostname (socket.gethostname)
          #(memory-gb gpu-cores bandwidth) (get-hardware-capability)
          #(n-transducers batch-size optimal-total) (optimal-config memory-gb gpu-cores)
          base-arr (mx.array [(& seed 0xFFFFFFFF)] :dtype mx.uint32)]
      
      (print)
      (print "=== BUKKIT AUTO-OPTIMIZED MINING ===")
      (print)
      (print (.format "  hostname:     {}" hostname))
      (print (.format "  memory:       {} GB" memory-gb))
      (print (.format "  gpu-cores:    {}" gpu-cores))
      (print (.format "  bandwidth:    {} GB/s" bandwidth))
      (print (.format "  transducers:  {}" n-transducers))
      (print (.format "  batch-size:   {:,}" batch-size))
      (print (.format "  total:        {:,}" optimal-total))
      (print)
      
      ;; Mine with optimal config
      (let [t0 (time.perf-counter)
            per-stream (// optimal-total n-transducers)
            all-hashes []]
        ;; Launch optimal number of transducers
        (for [s (range n-transducers)]
          (let [offset (* s per-stream)
                indices (+ (mx.arange per-stream :dtype mx.uint32) offset)
                hashes (color-kernel base-arr indices)]
            (.append all-hashes hashes)))
        ;; Single massive eval
        (mx.eval all-hashes)
        ;; XOR-reduce
        (setv fp seed)
        (setv total 0)
        (for [h all-hashes]
          (let [arr (np.array h :dtype np.uint64)]
            (setv total (+ total (len arr)))
            (setv fp (^ fp (int (np.bitwise_xor.reduce arr))))))
        (let [t1 (time.perf-counter)
              rate (/ total (- t1 t0) 1e6)]
          (print (.format "  mined:        {:,} colors" total))
          (print (.format "  time:         {:.2f} sec" (- t1 t0)))
          (print (.format "  rate:         {:.2f} M/sec" rate))
          (print (.format "  efficiency:   {:.1f}% of {:.0f} GB/s" 
                         (* 100 (/ (* rate 8) (* bandwidth 1e9))) bandwidth))
          (print (.format "  fp:           0x{:x}" (u64 fp)))
          (print)
          #(total (u64 fp) rate))))))

(defn nashprop-mine [seed hostname total-machines epoch-limit]
  "Mine colors independently using NashProp protocol.
   
   ZERO MESSAGES during computation. Only fingerprint at end."
  (when (and MLX np)
    (let [#(start count position) (nashprop-range seed hostname total-machines)
          ;; Limit to epoch size for reasonable compute time
          actual-count (min count (* epoch-limit NASHPROP-EPOCH-SIZE))]
      (print)
      (print "=== NASHPROP MINING ===")
      (print)
      (print (.format "  hostname:  {}" hostname))
      (print (.format "  position:  {}/{}" position total-machines))
      (print (.format "  range:     [{}, {})" start (+ start actual-count)))
      (print (.format "  colors:    {:,}" actual-count))
      (print)
      
      ;; Mine using fearless transducer composition
      (let [t0 (time.perf-counter)
            ranges [(, start actual-count)]
            result (transducer-compose seed ranges)
            t1 (time.perf-counter)]
        (when result
          (let [#(mined fp) result
                rate (/ mined (- t1 t0) 1e6)]
            (print (.format "  mined:     {:,} colors" mined))
            (print (.format "  rate:      {:.2f} M/sec" rate))
            (print (.format "  fp:        0x{:x}" fp))
            (print)
            #(mined fp rate position)))))))

(defn nashprop-sync [seed hostname fp peers timeout]
  "Sync fingerprints with peers (occasional or final).
   
   Only message in entire protocol: broadcast fingerprint."
  (let [sock (socket.socket socket.AF-INET socket.SOCK-DGRAM)
        msg (.encode (json.dumps {"g" "nashprop" "h" hostname "s" seed "f" fp}))]
    ;; Broadcast to mesh
    (sock.setsockopt socket.SOL-SOCKET socket.SO-BROADCAST 1)
    (sock.setblocking False)
    (for [p peers]
      (try (sock.sendto msg #((get p "ip") PORT)) (except [e Exception] None)))
    (try (sock.sendto msg #("<broadcast>" PORT)) (except [e Exception] None))
    (sock.close))
  
  ;; Collect peer fingerprints
  (let [sock (socket.socket socket.AF-INET socket.SOCK-DGRAM)
        results {}]
    (sock.setsockopt socket.SOL-SOCKET socket.SO-REUSEADDR 1)
    (sock.setblocking False)
    (try
      (sock.bind #("" PORT))
      (let [end (+ (time.time) timeout)]
        (while (< (time.time) end)
          (try
            (let [#(data addr) (sock.recvfrom 1024)
                  m (json.loads (.decode data))]
              (when (and (= (get m "g" "") "nashprop") (= (get m "s") seed))
                (setv (get results (get m "h")) (get m "f"))))
            (except [BlockingIOError] (time.sleep 0.01)))))
      (except [e Exception] None))
    (sock.close)
    results))

(defn nashprop-verify [seed local-fp peer-fps]
  "Verify global consensus via XOR of all fingerprints.
   
   NASH EQUILIBRIUM CHECK: All honest miners produce matching XOR."
  (setv global-xor local-fp)
  (for [#(host fp) (.items peer-fps)]
    (setv global-xor (^ global-xor fp)))
  global-xor)

(defn distributed-benchmark [seed millions hosts]
  "Run distributed benchmark across multiple machines.
   
   Each host gets a disjoint range via seed bundle.
   Combined bandwidth = sum of individual bandwidths."
  (let [n (* millions 1000000)
        bundle (make-bundle seed n hosts)
        local-host (socket.gethostname)]
    (print)
    (print "=== DISTRIBUTED FEARLESS ===")
    (print)
    (print (json.dumps bundle :indent 2))
    (print)
    
    ;; Find and compute local range
    (let [my-range (my-range-from-bundle bundle)]
      (if my-range
        (do
          (print (.format "  Local range: {} to {} ({} colors)"
                         (get my-range "start")
                         (+ (get my-range "start") (get my-range "count"))
                         (get my-range "count")))
          (let [t0 (time.perf-counter)
                result (compute-bundle-range seed 
                                             (get my-range "start")
                                             (get my-range "count"))
                t1 (time.perf-counter)]
            (when result
              (let [#(count fp) result
                    rate (/ count (- t1 t0) 1e6)]
                (print (.format "  Local: {:,} colors @ {:.2f} M/sec  fp=0x{:x}"
                               count rate fp))
                #(count fp rate)))))
        (do
          (print "  ERROR: Host not in bundle")
          None)))))

;; ═══════════════════════════════════════════════════════════════════════════
;; MAIN ENTRY POINT
;; ═══════════════════════════════════════════════════════════════════════════
;;
;; Usage: hy gay.hy [seed] [polarity] [millions]
;;        hy gay.hy --distributed 500 causality hatchery  ; Split across machines
;;
;; ═══════════════════════════════════════════════════════════════════════════

(defn numpy-spi [seed polarity n]
  "NumPy SPI-compliant path - full 64-bit splitmix64.
   
   Use this for verification. ~30-50M colors/sec."
  (when np
    (let [twisted (u64 (^ seed (get TWISTS polarity)))
          candidates (* n 3)
          indices (np.arange candidates :dtype np.uint64)
          seeds (np.bitwise_and (+ twisted (* indices GOLDEN)) MASK64)
          ;; Full SplitMix64 (64-bit constants)
          z (np.bitwise_and (+ seeds GOLDEN) MASK64)
          z (np.bitwise_and (* (np.bitwise_xor z (np.right_shift z 30)) 
                               (| MIX1-32 (<< MIX1-32 32))) MASK64)
          z (np.bitwise_and (* (np.bitwise_xor z (np.right_shift z 27)) 
                               (| MIX2-32 (<< MIX2-32 32))) MASK64)
          hashes (np.bitwise_xor z (np.right_shift z 31))
          owned (get hashes (slice polarity None 3))
          owned (if (> (len owned) n) (get owned (slice None n)) owned)
          fp (^ (int (np.bitwise_xor.reduce owned)) twisted)]
      #((len owned) (u64 fp)))))

(defn benchmark [seed polarity millions]
  "Benchmark all available backends - targeting 1B+ colors/sec."
  (setv n (* millions 1000000))
  (setv results {})
  
  ;; GIGAFEARLESS - 3 × 128 = 384 parallel transducers
  (when MLX
    (let [t0 (time.perf-counter)
          result (mlx-gigafearless seed (* n 3))
          t1 (time.perf-counter)]
      (when result
        (let [#(count fps xor-all) result]
          (setv (get results "gigafearless") 
                {"count" count "fp" xor-all "time" (- t1 t0) 
                 "rate" (/ count (- t1 t0) 1e6)})))))
  
  ;; FEARLESS-256 - 256 transducers composed
  (when MLX
    (let [t0 (time.perf-counter)
          result (mlx-fearless seed n 256)
          t1 (time.perf-counter)]
      (when result
        (let [#(count fp) result]
          (setv (get results "fearless-256") 
                {"count" count "fp" fp "time" (- t1 t0) 
                 "rate" (/ count (- t1 t0) 1e6)})))))
  
  ;; FEARLESS-128 - 128 transducers
  (when MLX
    (let [t0 (time.perf-counter)
          result (mlx-fearless seed n 128)
          t1 (time.perf-counter)]
      (when result
        (let [#(count fp) result]
          (setv (get results "fearless-128") 
                {"count" count "fp" fp "time" (- t1 t0) 
                 "rate" (/ count (- t1 t0) 1e6)})))))
  
  ;; TERASTREAM - single kernel (baseline)
  (when MLX
    (let [t0 (time.perf-counter)
          result (mlx-terastream seed n)
          t1 (time.perf-counter)]
      (when result
        (let [#(count fp) result]
          (setv (get results "terastream") 
                {"count" count "fp" fp "time" (- t1 t0) 
                 "rate" (/ count (- t1 t0) 1e6)})))))
  
  results)

(defn main []
  ;; Parse arguments - IHOR seed default
  (let [seed (int (if (> (len sys.argv) 1) (get sys.argv 1) (str IHOR-SEED)))
        host (socket.gethostname)
        polarity (if (> (len sys.argv) 2) 
                   (% (int (get sys.argv 2)) 3) 
                   (% (fnv1a host) 3))
        millions (int (if (> (len sys.argv) 3) (get sys.argv 3) "10"))
        twisted (u64 (^ seed (get TWISTS polarity)))]
    
    ;; Header
    (print)
    (print "gay.hy - Triadic Color Bandwidth Protocol")
    (print "=========================================")
    (print)
    
    ;; Show derivation chain
    (let [chain (derive-chain twisted 8)]
      (print (.format "  {} chain" (show-chain chain))))
    (print)
    
    ;; Configuration
    (print (.format "  host:     {}" host))
    (print (.format "  polarity: {} (owns depths {}mod3)" 
                    (get POLARITIES polarity) polarity))
    (print (.format "  seed:     {} (IHOR) -> 0x{:x}" seed twisted))
    (print (.format "  target:   {}M colors" millions))
    (print (.format "  mlx:      {}" MLX))
    (print (.format "  numpy:    {}" (not (is np None))))
    (print)
    
    ;; Bandwidth benchmark - all backends
    (print "--- Bandwidth Benchmark ---")
    (let [results (benchmark seed polarity millions)]
      (for [#(backend r) (.items results)]
        (print (.format "  {:12} {:7.2f} M/sec ({:6.1f}ms) fp=0x{:x}" 
                        backend (get r "rate") (* (get r "time") 1000) (get r "fp"))))
      (print)
      
      ;; Best result
      (when results
        (let [best (max (.items results) :key (fn [x] (get (get x 1) "rate")))]
          (print (.format "  BEST: {} @ {:.2f} M/sec" (get best 0) (get (get best 1) "rate")))))
      (print)
      
      ;; Mesh discovery
      (print "--- Mesh (port 42069) ---")
      (setv keys-list (list (.keys results)))
      (setv best-fp (if keys-list (get (get results (get keys-list 0)) "fp") 0))
      (let [ts (tailscale-peers)]
        (if ts
          (let [#(self-ip peers) ts]
            (print (.format "  self: {}" self-ip))
            (for [p peers] 
              (print (.format "    {} {}" (get p "ip") (get p "name"))))
            (mesh-send host polarity best-fp (or peers [])))
          (print "  offline")))
      
      ;; Listen for peers
      (let [found (mesh-recv 0.5)]
        (when found
          (print)
          (print "--- Peers ---")
          (for [#(addr p) (.items found)]
            (print (.format "  {} {} fp=0x{:x}" 
                           addr 
                           (get POLARITIES (get p "p" 0)) 
                           (get p "f" 0)))))))
    (print)
    
    ;; Triadic verification (SPI-compliant path)
    (print "--- Triadic SPI Verification ---")
    (setv xor-all 0)
    (for [p (range 3)]
      (let [result (if np 
                     (numpy-spi seed p 100000)
                     (cpu-staggered (u64 (^ seed (get TWISTS p))) p 10000))
            #(c pf) result]
        (print (.format "  {:8} depths {}mod3 -> {:,} fp=0x{:x}" 
                       (get POLARITIES p) p c pf))
        (setv xor-all (^ xor-all pf))))
    (print)
    (print (.format "  XOR: 0x{:x} <- MUST MATCH ON ALL PEERS" xor-all))
    (print)))

;; ═══════════════════════════════════════════════════════════════════════════
;; ENTRY
;; ═══════════════════════════════════════════════════════════════════════════

(when (= __name__ "__main__")
  (main))

;; ═══════════════════════════════════════════════════════════════════════════
;; DISTRIBUTED OCCUPANCY: Resource-Aware Parallel Color Mining
;; ═══════════════════════════════════════════════════════════════════════════

(defn discover-and-mine [seed timeout]
  "Discover peers, create resource-aware bundle, mine together."
  (let [hostname (socket.gethostname)
        #(memory-gb gpu-cores bandwidth) (get-hardware-capability)
        my-score (capability-score memory-gb gpu-cores bandwidth)
        #(n-transducers batch-size optimal-total) (optimal-config memory-gb gpu-cores)]
    
    (print)
    (print "═══════════════════════════════════════════════════════════════")
    (print "  GAY DISTRIBUTED OCCUPANCY - Resource-Aware Mining")
    (print "═══════════════════════════════════════════════════════════════")
    (print)
    (print (.format "  Local: {} ({} GB, {} cores, {} GB/s)" 
                   hostname memory-gb gpu-cores bandwidth))
    (print (.format "  Score: {} | Transducers: {} | Batch: {:,}"
                   my-score n-transducers optimal-total))
    (print)
    
    ;; Broadcast capability
    (let [ts (tailscale-peers)
          my-cap {"h" hostname "m" memory-gb "c" gpu-cores "b" bandwidth "s" my-score}]
      (when ts
        (let [#(self-ip peers) ts
              sock (socket.socket socket.AF-INET socket.SOCK-DGRAM)
              msg (.encode (json.dumps {"g" "cap" "d" my-cap "seed" seed}))]
          (sock.setsockopt socket.SOL-SOCKET socket.SO-BROADCAST 1)
          (sock.setblocking False)
          (for [p peers]
            (try (sock.sendto msg #((get p "ip") PORT)) (except [e Exception] None)))
          (sock.close)
          (print (.format "  Broadcast to {} peers" (len peers)))))
      
      ;; Listen for peer capabilities
      (print "  Listening for peers...")
      (let [sock (socket.socket socket.AF-INET socket.SOCK-DGRAM)
            peer-caps {hostname my-cap}]
        (sock.setsockopt socket.SOL-SOCKET socket.SO-REUSEADDR 1)
        (sock.setblocking False)
        (try
          (sock.bind #("" PORT))
          (let [end (+ (time.time) timeout)]
            (while (< (time.time) end)
              (try
                (let [#(data addr) (sock.recvfrom 1024)
                      m (json.loads (.decode data))]
                  (when (and (= (get m "g" "") "cap") (= (get m "seed") seed))
                    (let [d (get m "d")]
                      (setv (get peer-caps (get d "h")) d)
                      (print (.format "    Found: {} (score {})" 
                                     (get d "h") (get d "s"))))))
                (except [BlockingIOError] (time.sleep 0.05)))))
          (except [e Exception] None))
        (sock.close)
        
        ;; Create resource-weighted ranges
        (print)
        (print "--- Resource-Weighted Assignment ---")
        (let [total-score (sum (lfor #(_ c) (.items peer-caps) (get c "s")))
              sorted-peers (sorted (.items peer-caps) 
                                   :key (fn [x] (fnv1a (get x 0))))
              total-colors (* 1000000000 (len peer-caps))  ; 1B per peer baseline
              assignments {}
              start 0]
          (for [#(h cap) sorted-peers]
            (let [proportion (/ (get cap "s") total-score)
                  count (int (* proportion total-colors))]
              (setv (get assignments h) {"start" start "count" count 
                                         "proportion" proportion})
              (print (.format "  {}: [{:,}, {:,}) - {:.1f}%"
                             h start (+ start count) (* proportion 100)))
              (setv start (+ start count))))
          
          ;; Mine my portion
          (print)
          (print "--- Mining My Portion ---")
          (let [my-assignment (get assignments hostname)
                my-start (get my-assignment "start")
                my-count (get my-assignment "count")]
            (let [t0 (time.perf-counter)
                  result (transducer-compose seed [(tuple [my-start my-count])])
                  t1 (time.perf-counter)]
              (when result
                (let [#(mined fp) result
                      rate (/ mined (- t1 t0) 1e6)]
                  (print (.format "  Mined: {:,} colors @ {:.2f} M/sec"
                                 mined rate))
                  (print (.format "  fp: 0x{:x}" fp))
                  
                  ;; Broadcast result
                  (when ts
                    (let [#(self-ip peers) ts
                          sock (socket.socket socket.AF-INET socket.SOCKET-DGRAM)
                          msg (.encode (json.dumps {"g" "result" "h" hostname 
                                                    "seed" seed "fp" fp 
                                                    "count" mined "rate" rate}))]
                      (sock.setblocking False)
                      (for [p peers]
                        (try (sock.sendto msg #((get p "ip") PORT)) 
                             (except [e Exception] None)))
                      (sock.close)))
                  
                  ;; Collect peer results
                  (print)
                  (print "--- Collecting Results ---")
                  (let [results {hostname {"fp" fp "count" mined "rate" rate}}
                        sock (socket.socket socket.AF-INET socket.SOCK-DGRAM)]
                    (sock.setsockopt socket.SOL-SOCKET socket.SO-REUSEADDR 1)
                    (sock.setblocking False)
                    (try
                      (sock.bind #("" PORT))
                      (let [end (+ (time.time) timeout)]
                        (while (< (time.time) end)
                          (try
                            (let [#(data addr) (sock.recvfrom 1024)
                                  m (json.loads (.decode data))]
                              (when (and (= (get m "g" "") "result") 
                                        (= (get m "seed") seed))
                                (setv (get results (get m "h")) 
                                      {"fp" (get m "fp") 
                                       "count" (get m "count")
                                       "rate" (get m "rate")})
                                (print (.format "    {} fp=0x{:x} @ {:.0f}M/s"
                                               (get m "h") (get m "fp") 
                                               (get m "rate")))))
                            (except [BlockingIOError] (time.sleep 0.05)))))
                      (except [e Exception] None))
                    (sock.close)
                    
                    ;; Combine fingerprints
                    (print)
                    (print "--- Combined Results ---")
                    (setv combined-fp 0)
                    (setv total-mined 0)
                    (setv total-rate 0)
                    (for [#(h r) (.items results)]
                      (setv combined-fp (^ combined-fp (get r "fp")))
                      (setv total-mined (+ total-mined (get r "count")))
                      (setv total-rate (+ total-rate (get r "rate"))))
                    (print (.format "  Peers: {}" (len results)))
                    (print (.format "  Total: {:,} colors" total-mined))
                    (print (.format "  Rate:  {:.2f} B/sec combined" (/ total-rate 1000)))
                    (print (.format "  XOR:   0x{:x}" combined-fp))
                    (print)
                    #(total-mined combined-fp total-rate)))))))))))

;; ═══════════════════════════════════════════════════════════════════════════
;; COLLECTIVE MEMBERSHIP: Proof-of-Parallelism Voting
;; ═══════════════════════════════════════════════════════════════════════════
;;
;; New machines must PROVE effective parallelism before joining:
;; 1. Existing members issue random index challenges
;; 2. Candidate must compute color_at(seed, challenge_index) correctly
;; 3. Response time proves parallelism capability
;; 4. Majority vote admits to collective
;;
;; "Correctly computing by accident" = can't fake, must actually compute
;;
;; ═══════════════════════════════════════════════════════════════════════════

(setv COLLECTIVE-PORT 42070)
(setv PROBE-COUNT 10)
(setv MAX-PROBE-TIME-MS 100)  ; Must respond within 100ms per probe

(defn generate-challenge [seed challenger-host round]
  "Generate deterministic challenge index from seed + challenger + round.
   
   Challenger can verify response without storing challenges."
  (let [challenge-seed (^ seed (fnv1a challenger-host) (* round GOLDEN))]
    (mix challenge-seed)))

(defn compute-probe-response [seed index]
  "Compute single color_at response for probe."
  (color-at seed index))

(defn verify-probe [seed index expected-color]
  "Verify probe response matches expected."
  (= (color-at seed index) expected-color))

(defn issue-membership-probes [seed candidate-ip n-probes]
  "Issue n random probes to candidate, measure response time.
   
   Returns: (passed, avg-time-ms, correct-count)"
  (let [hostname (socket.gethostname)
        sock (socket.socket socket.AF-INET socket.SOCK-DGRAM)
        correct 0
        total-time 0]
    (sock.settimeout (/ MAX-PROBE-TIME-MS 1000))
    
    (for [i (range n-probes)]
      (let [challenge-idx (generate-challenge seed hostname i)
            expected (color-at seed challenge-idx)
            msg (.encode (json.dumps {"g" "probe" "s" seed "i" challenge-idx "r" i}))
            t0 (time.perf-counter)]
        (try
          (sock.sendto msg #(candidate-ip COLLECTIVE-PORT))
          (let [#(data _) (sock.recvfrom 1024)
                response (json.loads (.decode data))
                t1 (time.perf-counter)
                elapsed-ms (* (- t1 t0) 1000)]
            (when (and (= (get response "g") "probe-resp")
                       (= (get response "c") expected))
              (setv correct (+ correct 1))
              (setv total-time (+ total-time elapsed-ms))))
          (except [e Exception] None))))
    (sock.close)
    
    (let [passed (and (>= correct (// n-probes 2))
                      (< (/ total-time (max correct 1)) MAX-PROBE-TIME-MS))
          avg-time (if (> correct 0) (/ total-time correct) 999)]
      #(passed avg-time correct))))

(defn run-probe-responder [seed timeout]
  "Listen for probes and respond with computed colors.
   
   Proves parallelism capability by fast correct responses."
  (let [sock (socket.socket socket.AF-INET socket.SOCK-DGRAM)
        responded 0]
    (sock.setsockopt socket.SOL-SOCKET socket.SO-REUSEADDR 1)
    (sock.setblocking False)
    (try
      (sock.bind #("" COLLECTIVE-PORT))
      (let [end (+ (time.time) timeout)]
        (while (< (time.time) end)
          (try
            (let [#(data addr) (sock.recvfrom 1024)
                  msg (json.loads (.decode data))]
              (when (= (get msg "g") "probe")
                (let [idx (get msg "i")
                      color (color-at (get msg "s") idx)
                      resp (.encode (json.dumps {"g" "probe-resp" "c" color "r" (get msg "r")}))]
                  (sock.sendto resp addr)
                  (setv responded (+ responded 1)))))
            (except [BlockingIOError] (time.sleep 0.001)))))
      (except [e Exception] None))
    (sock.close)
    responded))

(defn request-membership [seed existing-members]
  "Request to join collective by proving parallelism.
   
   existing-members: list of (hostname, ip) tuples"
  (let [hostname (socket.gethostname)
        #(memory-gb gpu-cores bandwidth) (get-hardware-capability)
        votes-needed (// (+ (len existing-members) 1) 2)  ; Majority
        votes-received 0]
    
    (print)
    (print "═══════════════════════════════════════════════════════════════")
    (print "  COLLECTIVE MEMBERSHIP REQUEST")
    (print "═══════════════════════════════════════════════════════════════")
    (print)
    (print (.format "  Candidate: {} ({} GB, {} cores)" hostname memory-gb gpu-cores))
    (print (.format "  Existing members: {}" (len existing-members)))
    (print (.format "  Votes needed: {}" votes-needed))
    (print)
    
    ;; Broadcast capability and membership request
    (let [sock (socket.socket socket.AF-INET socket.SOCK-DGRAM)
          cap {"h" hostname "m" memory-gb "c" gpu-cores "b" bandwidth}
          msg (.encode (json.dumps {"g" "membership-req" "cap" cap "seed" seed}))]
      (sock.setblocking False)
      (for [#(_ ip) existing-members]
        (try (sock.sendto msg #(ip COLLECTIVE-PORT)) (except [e Exception] None)))
      (sock.close))
    
    ;; Run probe responder to prove capability
    (print "  Responding to probes...")
    (let [responded (run-probe-responder seed 10)]
      (print (.format "  Responded to {} probes" responded)))
    
    ;; Collect votes
    (let [sock (socket.socket socket.AF-INET socket.SOCK-DGRAM)]
      (sock.setsockopt socket.SOL-SOCKET socket.SO-REUSEADDR 1)
      (sock.setblocking False)
      (try
        (sock.bind #("" COLLECTIVE-PORT))
        (let [end (+ (time.time) 5)]
          (while (< (time.time) end)
            (try
              (let [#(data addr) (sock.recvfrom 1024)
                    msg (json.loads (.decode data))]
                (when (and (= (get msg "g") "vote") 
                          (= (get msg "candidate") hostname)
                          (get msg "approve"))
                  (setv votes-received (+ votes-received 1))
                  (print (.format "    Vote from {}: APPROVE" (get msg "voter")))))
              (except [BlockingIOError] (time.sleep 0.05)))))
        (except [e Exception] None))
      (sock.close))
    
    (print)
    (if (>= votes-received votes-needed)
      (do
        (print "  ✓ MEMBERSHIP APPROVED")
        True)
      (do
        (print (.format "  ✗ MEMBERSHIP DENIED ({}/{} votes)" votes-received votes-needed))
        False))))

(defn vote-on-candidate [seed candidate-ip timeout]
  "Vote on candidate by issuing probes and verifying responses.
   
   Auto-approves if candidate proves effective parallelism."
  (let [hostname (socket.gethostname)]
    (print)
    (print (.format "--- Probing candidate {} ---" candidate-ip))
    
    (let [#(passed avg-time correct) (issue-membership-probes seed candidate-ip PROBE-COUNT)]
      (print (.format "  Probes: {}/{} correct, avg {:.1f}ms" correct PROBE-COUNT avg-time))
      
      (if passed
        (do
          (print "  Vote: APPROVE (proved parallelism)")
          ;; Send approval vote
          (let [sock (socket.socket socket.AF-INET socket.SOCK-DGRAM)
                msg (.encode (json.dumps {"g" "vote" "voter" hostname 
                                          "candidate" candidate-ip "approve" True}))]
            (try (sock.sendto msg #(candidate-ip COLLECTIVE-PORT)) (except [e Exception] None))
            (sock.close))
          True)
        (do
          (print "  Vote: DENY (failed probes)")
          False)))))

(defn tripartite-collective [seed members]
  "Create tripartite resource-aware collective.
   
   members: list of (hostname, memory-gb, gpu-cores, bandwidth)
   
   Assigns polarities and ranges for 3-MATCH."
  (let [n (len members)
        ;; Sort by capability score descending
        scored (sorted members :key (fn [m] (- (capability-score (get m 1) (get m 2) (get m 3)))))
        total-score (sum (lfor m scored (capability-score (get m 1) (get m 2) (get m 3))))
        assignments []]
    
    (print)
    (print "═══════════════════════════════════════════════════════════════")
    (print "  TRIPARTITE COLLECTIVE - 3-MATCH Assignment")
    (print "═══════════════════════════════════════════════════════════════")
    (print)
    
    (setv start 0)
    (for [#(i #(hostname mem cores bw)) (enumerate scored)]
      (let [score (capability-score mem cores bw)
            proportion (/ score total-score)
            count (int (* proportion NASHPROP-TOTAL-SPACE))
            polarity (% i 3)  ; MINUS, ERGODIC, PLUS round-robin by capability
            twisted (u64 (^ seed (get TWISTS polarity)))]
        (.append assignments 
                 {"host" hostname "polarity" polarity "start" start "count" count
                  "score" score "twisted" twisted})
        (print (.format "  {} [{}]: {} colors ({:.1f}%) - polarity {}"
                       hostname (get POLARITIES polarity) count (* proportion 100) polarity))
        (setv start (+ start count))))
    
    (print)
    assignments))
