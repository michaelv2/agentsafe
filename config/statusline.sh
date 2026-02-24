#!/usr/bin/env python3
"""Claude Code statusline script."""
import json
import sys

raw = sys.stdin.read()

try:
    data = json.loads(raw)
except (json.JSONDecodeError, ValueError):
    data = {}

# Extract fields
model = data.get("model", {}).get("display_name") or "?"
cwd = data.get("workspace", {}).get("current_dir") or "~"
ctx_pct = float(data.get("context_window", {}).get("used_percentage") or 0)
cost = data.get("cost", {}).get("total_cost_usd", 0)

# Shorten directory path
if len(cwd) > 30:
    cwd_short = "..." + cwd[-27:]
else:
    cwd_short = cwd

# Build context progress bar [━━━╌╌╌╌╌╌╌] - 10 chars wide
ctx_int = int(ctx_pct)
ctx_filled = ctx_int // 10
ctx_empty = 10 - ctx_filled
ctx_bar = "\u2501" * ctx_filled + "\u254c" * ctx_empty

# Color thresholds for context
if ctx_int >= 85:
    ctx_color = "\033[31m"  # red
elif ctx_int >= 60:
    ctx_color = "\033[33m"  # yellow
else:
    ctx_color = "\033[32m"  # green
reset_color = "\033[0m"

# Format cost
cost_str = f"${cost:.2f}" if cost else "$0.00"

sys.stdout.write(
    f"{model} \u2502 {cwd_short}"
    f" \u2502 Ctx [{ctx_color}{ctx_bar}{reset_color}] {ctx_int}%"
    f" \u2502 Cost: {cost_str}"
)
