---
description: Clear the review gate and allow the session to stop
---

Run:

```bash
${CLAUDE_PLUGIN_ROOT}/bin/review-gate resolve --reason "manual clear"
```

This resolves the active review gate, allowing you to stop the session without completing the review cycle.
