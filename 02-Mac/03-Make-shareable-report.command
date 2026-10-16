#!/bin/bash
# Double-click to make a copy of the report that is safe to share: names, folders and accounts are
# replaced with placeholders, and the real values are not in the file. Saved as 04-reports/repos-shared.html
exec bash "$(dirname "$0")/01-Run-on-Mac.command" -Redact "$@"
