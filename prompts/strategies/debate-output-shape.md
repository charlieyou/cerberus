Under `--debate`, also include `confidence` (0.0–1.0) on each finding and `overall_confidence` (0.0–1.0) at the top level:
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
  ],
  "verdict": "PASS",
  "summary": "1-3 sentence explanation",
  "overall_confidence": 0.8
}
