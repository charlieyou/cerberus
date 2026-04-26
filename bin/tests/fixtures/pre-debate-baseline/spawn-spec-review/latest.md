<!-- review-type: spec -->
<!-- spec-path: <CAPTURE_WORKDIR>/sample-spec.md -->
<!-- spec-sha: 1c7947d0ba9c62ad34c6fcbe4ea6284bfb86d9b00336594d0e65744e4a389c58 -->
<!-- max-rounds: 3 -->
<!-- agents: codex,gemini,claude -->
<!-- mode: smart -->

# Spec Review (Iterative)

## Spec Path
<CAPTURE_WORKDIR>/sample-spec.md

## Spec Content

<spec-content>
# Feature Specification: Pre-Debate Baseline Fixtures

## Overview

Capture pre-feature golden fixtures for all five review-gate invocation shapes
before any debate-mode prompt-template changes land.

## Requirements

### R0 — Fixture Capture

The capture script MUST run synchronously and produce deterministic output
by substituting all three reviewer CLIs with canned offline counterparts.

### R1 — Prompt Fidelity

The rendered prompt captured for each shape MUST be byte-identical to what
the plugin would produce when invoked interactively with the same arguments.

### R2 — Schema Stability

The review-schema.json MUST be captured verbatim; no structural change is
permitted to the pre-debate schema.

## Acceptance Criteria

- AC-StepZero: All 5 shapes produce non-empty captures.
- AC-PromptFidelity: Captured prompts match interactive invocation.
- AC-SchemaStability: Schema is identical to interactive invocation schema.
</spec-content>
