Strategy: deployment-safety.
Focus on rollout and rollback risks introduced by the diff: migrations, config or environment changes, feature flags, backwards compatibility with existing data, dependency or service ordering, API compatibility, and observability.
Ask whether this change can be deployed safely while old and new versions, old data, or partially applied configuration may coexist.
Report missing logs, metrics, alerts, or error surfacing only when a production failure would otherwise be silent or hard to diagnose.
Do not flag generic operational best practices unless the diff creates a concrete deployment, rollback, or detection risk.
