#!/bin/bash
# Shortens xcodebuild output (and annotates errors on GitHub) when xcbeautify is installed.
if command -v xcbeautify >/dev/null 2>&1; then
  if [ -n "${GITHUB_ACTIONS:-}" ]; then exec xcbeautify --renderer github-actions; else exec xcbeautify; fi
fi
exec cat
