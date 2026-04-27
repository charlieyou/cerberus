R1 Anonymization fixtures (T007 / Phase E.1)
============================================

These fixtures pin the byte-stable inputs and expected outputs of the R1
anonymization helpers in `bin/review-gate-debate.sh`:

- Deny-list scrub (canonical POSIX ERE iterative substitution loop).
- Active / abstained peer skeleton rendering.
- Seeded per-recipient peer ordering (`--debate-seed N` algorithm).

Cross-platform contract (spec R1):

- The deny-list scrub uses POSIX ERE under `sed -E` with the canonical
  `(^|[^A-Za-z0-9_])(<terms>)($|[^A-Za-z0-9_])` boundary form. Both BSD
  (macOS) and GNU (Linux) `sed` produce byte-identical scrub output, so
  one committed `*.expected.txt` covers both platforms.
- The seeded peer-ordering uses SHA-256 over `<seed>:<recipient>:<peer>`
  via the `_sha256_hex` helper from T005 (`shasum -a 256` preferred,
  `sha256sum` fallback). Both tools emit identical digests, and the
  byte-order sort is locale-independent (`LC_ALL=C sort`), so the
  ordering is byte-stable across macOS and Linux.

File layout:

- `denylist-*.input.txt` / `.expected.txt`     — single-input scrub cases.
- `adjacent-*.input.txt` / `.expected.txt`     — adjacent-term iteration.
- `negative-non-matches.input.txt` / `.expected.txt` — counter-examples that
  MUST NOT be redacted.
- `active-peer-*.input.json` / `.expected.txt` — active-peer skeleton.
- `abstained-peer.expected.txt`                 — abstained-peer skeleton.
- `seeded-ordering.json`                        — seeded peer-ordering tuples
  with pre-computed expected orderings.
