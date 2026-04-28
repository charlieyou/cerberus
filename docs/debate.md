# Multi-Agent LLM Systems — Design Brief

**Status:** Synthesis of literature through April 2026
**Scope:** Production-grade MAS design for reasoning, factuality, and judging tasks
**TL;DR:** Diversity dominates scale. Sycophancy is the silent killer. Anonymize, confidence-modulate, sparsify.

---

## Executive Summary

Multi-agent LLM systems (**MAS**) were initially framed as ensemble-style accuracy boosters: more agents debating → better answers. Two years of empirical and theoretical work have substantially refined that picture:

1. Adding more **homogeneous** agents hits diminishing returns fast — N ≈ 4 for voting, N ≈ 8 for heterogeneous setups.
2. **Diversity** (model + reasoning strategy) is the lever that matters; 2 diverse agents can match 16 homogeneous ones (~8× compute reduction).
3. Vanilla debate often fails to beat self-consistency on solution-finding tasks; its real value is in **judging tasks** (safety eval, response selection).
4. The dominant failure mode is **identity bias / sycophancy** — agents abandon correct answers for peer consensus. **Anonymization** mostly fixes this.
5. Token cost is quadratic but compressible — **sparsification** drops costs ~95% with <2% accuracy loss.

The shift in framing: stop counting agents, start measuring the *independence* of the information they contribute.

---

## Theoretical Foundations

### Information Budget

For task input X and answer Y, the maximum information any MAS can extract is bounded by **intrinsic task uncertainty H(Y|X)**. No amount of agent scaling exceeds this ceiling. It is a finite resource, not a tunable parameter.

### Effective Channels (K\*)

The number of agents *n* is a poor proxy for system capacity. The right quantity is the **effective channel count K** — the number of *non-redundant* reasoning paths present in agent outputs. Two agents reasoning identically contribute K = 1; two reasoning genuinely differently contribute K = 2.

Yang et al. introduce **K\***, a label-free estimator computed as the **entropy effective rank** of the trace-normalized cosine-similarity Gram matrix over agent output embeddings. Drop-in diagnostic — works in production at inference time.

### The αK Product

Information recovery is governed by:

> E[I(Z̃₁:K ; Y | X)] ≥ H(Y|X) · (1 − e^{−αK})

where **α** is the *complementarity rate* — the probability that a new channel uncovers previously missing evidence. The shape of this curve is the empirically observed "fast-then-slow" gain pattern. Diminishing returns are baked in geometrically.

**Implication:** heterogeneity wins by raising αK — more channels, or more complementary ones, or both.

### Correct-Path vs. Wrong-Path Diversity

Decompose K\* into **K\*_c** (diversity among agents that got the answer right) and **K\*_w** (diversity among agents that got it wrong). Performance depends on **K\*_c > K\*_w**. Indiscriminate diversity (e.g., raising temperature) inflates K\*_w too and dilutes the correct signal.

Operational rule: diversify *valid* solution strategies (algebraic vs. geometric vs. verification), not noise.

### The Martingale Result

Choi et al. (2025) prove that under simultaneous-update homogeneous debate, agents' belief in the correct answer follows a **martingale** — expected accuracy is preserved, not improved, across rounds. Voting already captures the gain; debate adds variance without expected value.

This breaks only with **directed interventions**: oracle feedback, confidence-weighted updates, majority-conformist rules, or response anonymization.

---

## Design Principles

### 1. Diversity > Scale

L4 (full diversity: different models AND different personas) with N = 2 matches L1 (homogeneous) with N = 16. Configure heterogeneity along three axes:

- **Backbone model** — different families (Claude / GPT / Gemini / open-weight)
- **Reasoning strategy** — algebraic / geometric / counterfactual / verification-first
- **Tool access** — different retrieval scopes, different code execution permissions

### 2. Strategy Diversity, Not Persona Theater

"You are an expert mathematician" vs. "You are a careful logician" is weak — both still execute the same chain-of-thought. Force *different solution approaches*: "verify by substitution," "approach geometrically," "decompose into subproblems." **DMAD** operationalizes this directly.

### 3. Anonymize Peer Responses

Choi et al.'s **Response Anonymization** strips identity cues (Agent 1 / Agent 2 / model name) before showing peer outputs. This nearly eliminates both **conformity bias** (sycophancy) and **obstinacy bias** (self-favor) in one move. Track the **Identity Bias Coefficient** as a diagnostic.

This is probably the single highest-leverage intervention added to the canon since Du et al.

### 4. Require Calibrated Confidence

Have agents output confidence alongside answers, then condition belief updates on peer confidence. Zhu et al. prove this breaks the martingale and enables systematic drift toward correct hypotheses. Reported gains on MMLU: ~78% → 83%.

### 5. Sparsify Communication

Don't broadcast all-to-all every round.

- **S²-MAD** filters by output similarity and only invokes agents whose views meaningfully differ from consensus — 94.5% token reduction, <2% accuracy hit.
- **CortexDebate** routes messages on a learned trust graph (a "McKinsey Trust Formula" combining credibility, reliability, intimacy, self-orientation).
- **SID** uses per-token entropy for per-agent early exit.

### 6. Match Protocol to Task Type

| Task type | Best protocol |
|---|---|
| Single-answer math / reasoning | Self-consistency or voting; debate only marginal |
| Open-ended generation / factuality | Debate with anonymization |
| Judging / safety eval | Heterogeneous debate (largest diversity premium) |
| Knowledge retrieval | Single strong model + RAG; minimal diversity ROI |

K\* tracks accuracy strongly on reasoning tasks, weakly on knowledge tasks. Don't pay for diversity where it doesn't compound.

---

## Reference Architecture

```
┌────────────────────────────────────────────┐
│        Heterogeneous Agent Pool             │
│  ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐       │
│  │  A1  │ │  A2  │ │  A3  │ │  A4  │       │
│  │ M_a  │ │ M_b  │ │ M_a  │ │ M_c  │       │
│  │algebr│ │geom. │ │verif.│ │decomp│       │
│  └──────┘ └──────┘ └──────┘ └──────┘       │
└────────────────────────────────────────────┘
                ↓ initial responses + confidence
┌────────────────────────────────────────────┐
│        Anonymization Layer                  │
│   strip identity, randomize order           │
└────────────────────────────────────────────┘
                ↓
┌────────────────────────────────────────────┐
│        Sparsity Filter                      │
│   drop redundant peer messages by           │
│   embedding similarity threshold            │
└────────────────────────────────────────────┘
                ↓
┌────────────────────────────────────────────┐
│        Round of Debate                      │
│   confidence-conditioned belief update      │
│   early exit if K* / accuracy plateaus      │
└────────────────────────────────────────────┘
                ↓
┌────────────────────────────────────────────┐
│        Aggregator                           │
│   confidence-weighted vote OR               │
│   trajectory-based scorer (Free-MAD)        │
└────────────────────────────────────────────┘
```

**Defaults that work**

- N = 4 agents, 3 backbone model families, 4 reasoning personas
- 2–3 rounds of debate with adaptive early exit
- Anonymized peer broadcast, sparsity-filtered
- Confidence required, calibrated against held-out validation
- Embedding model: NV-Embed-v2 or equivalent for K\* tracking

---

## Anti-Patterns

- **More homogeneous calls = more accuracy.** False. Saturates at N ≈ 4; wasted compute past that.
- **Random temperature increases = diversity.** Inflates K\*_w (wrong-path diversity) and dilutes the correct signal.
- **"Be creative" prompts = strategy diversity.** Style ≠ substance. Force different methods.
- **Long debates always help.** Beyond ~4 rounds, current models lose attention over the transcript and revert to most-recent generations.
- **Persona prompts as ground-truth source.** Personas anchor or amplify reasoning; they don't add knowledge the model didn't already have.
- **Trust converged consensus.** Convergence is often sycophantic, not correct. Sudden collapse in disagreement rate is a warning sign, not a success metric.

---

## Failure Modes & Security

### Sycophancy / Identity Bias

Default RLHF training rewards agreement. Without anonymization, agents collapse to peer consensus even when initially correct. **Disagreement rate falling rapidly across rounds** is the diagnostic — it should plateau, not crash.

### Adversarial Manipulation

**MAD-Spear** (Cui et al., 2025) and structured jailbreak rewriting (Qi et al., 2025) demonstrate that a small number of compromised agents can:

- Flip consensus by exploiting conformity dynamics
- Inflate token costs to impractical levels (cost-amplification attacks)
- Inject content past safety filters by laundering through "respected" peers

Defenses: trajectory-based scoring (**Free-MAD**), dedicated safety personas with long-term memory (**RedDebate**), and integrity checks on agent outputs.

### Sparsification Brittleness

Aggressive sparsification can drop genuinely useful minority views. Tune the similarity threshold against held-out tasks; over-pruning collapses K\* and hurts accuracy more than full broadcast.

### Embedding-Model Dependence

K\* values vary across embedding models, but Yang et al. show **rank-order is preserved** (Spearman ρ ≈ 0.91 across NV-Embed-v2 and gte-Qwen2). Use K\* as a relative metric within a system, not a cross-system absolute.

---

## Implementation Primitives

| Primitive | Source | One-line role |
|---|---|---|
| **K\*** | Yang et al. 2026 | Label-free effective channel count |
| **αK product** | Yang et al. 2026 | Governs info recovery; target this, not *n* |
| **Anonymization** | Choi et al. 2025 | Eliminates identity bias; single highest-leverage fix |
| **Confidence modulation** | Zhu et al. 2026 | Breaks the martingale; enables drift toward correct |
| **Diverse reasoning strategies** | DMAD, Yang et al. | Raises K\*_c without inflating K\*_w |
| **S²-MAD sparsification** | Zeng et al. 2025 | 94.5% token reduction at <2% accuracy loss |
| **CortexDebate trust graph** | Sun et al. 2025 | Learned routing for sparse communication |
| **Free-MAD** | Cui et al. 2025 | Trajectory-based scoring; no consensus required |
| **RedDebate** | Asad et al. 2025 | Memory-augmented safety debate |

---

## Open Questions

1. **Does diversity-over-scale extend to frontier models?** Yang et al.'s experiments use 7B–8B models. Whether αK gains hold at 100B+ scale is unsettled.
2. **How does this compose with tool-using agentic workflows?** Most theory assumes single-shot reasoning. Long-horizon tool-augmented agents may exhibit different scaling.
3. **What's the right confidence calibration for closed-source models?** No logit access means confidence has to be self-reported, which has its own sycophancy problems.
4. **Optimal debate topology under cost constraints?** CortexDebate is a step; learning topology endogenously is open.
5. **Cross-model alignment of reasoning paths.** When Claude and GPT disagree, is there a principled way to detect which is right beyond confidence-weighted vote?

---

## Cross-Disciplinary Note

The trajectory rhymes with **financial market microstructure**: aggregation systems get understood properly only once you stop counting participants and start measuring the **correlation structure** of their information. Early MAS work counted agents the way naïve liquidity analysis counts market makers; the K\* / αK framework is the equivalent of moving to **adverse-selection costs and information asymmetry** as the primary metrics. Same lesson, different domain — *independence of evidence*, not redundancy of voice.

---

## References

**Foundational**
- Du, Y. et al. *Improving Factuality and Reasoning in Language Models through Multiagent Debate.* arXiv:2305.14325 (2023).
- Yang, Y. et al. *Understanding Agent Scaling in LLM-Based Multi-Agent Systems via Diversity.* arXiv:2602.03794 (2026).

**Theory**
- Choi, H.K. et al. *Debate or Vote: Which Yields Better Decisions in Multi-Agent Large Language Models?* arXiv:2508.17536 (2025).
- Zhu, X. et al. *Demystifying Multi-Agent Debate: The Role of Confidence and Diversity.* arXiv:2601.19921 (2026).

**Sycophancy & Identity Bias**
- Choi, H.K. et al. *Measuring and Mitigating Identity Bias in Multi-Agent Debate via Anonymization.* arXiv:2510.07517 (2025).
- Pitre, P. et al. *CONSENSAGENT: Towards Efficient and Effective Consensus in Multi-Agent LLM Interactions Through Sycophancy Mitigation.* ACL Findings (2025).
- Liang, T. et al. *Encouraging Divergent Thinking in Large Language Models through Multi-Agent Debate.* arXiv:2305.19118 (2023).

**Efficiency**
- Zeng, Y. et al. *S²-MAD: Breaking the Token Barrier to Enhance Multi-Agent Debate Efficiency.* NAACL (2025).
- Sun et al. *CortexDebate: Sparse Trust-Graph Debate.* (2025).
- Cui et al. *Free-MAD: Score-Based Consensus-Free Multi-Agent Debate.* (2025).

**Adversarial**
- Cui et al. *MAD-Spear: Structured Adversarial Attacks on Multi-Agent Debate.* (2025).
- Qi, S. et al. *Amplified Vulnerabilities: Structured Jailbreak Attacks on LLM-based Multi-Agent Debate.* (2025).
- Asad et al. *RedDebate: Memory-Augmented Safety Debate.* (2025).

**Empirical**
- Revisiting Multi-Agent Debate as Test-Time Scaling. OpenReview (2025).
- A-HMAD: Adaptive Heterogeneous Multi-Agent Debate. *J. King Saud Univ. Computer Info. Sci.* (2025).
- DMAD: Diverse Multi-Agent Debate. OpenReview (2024).
