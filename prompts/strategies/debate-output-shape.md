{
  "findings": [
    {
      "title": "[P1] <= 80 chars, imperative",
      "body": "Markdown explaining the issue.",
      "priority": 1,
      "file_path": "path/to/file.py",
      "line_start": 42,
      "line_end": 45,
      "confidence": 0.85
    }
  ]
}

Final output must be valid JSON only with exactly one top-level key, `findings`. Do not include top-level `verdict`, `summary`, `overall_confidence`, `strategy`, `round`, or `peer_responses_seen`; Cerberus derives verdicts from finding priorities. Each finding must include `confidence` (0.0-1.0, or null if unavailable). If there are no findings, return `{"findings": []}`.
