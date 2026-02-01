# AGENTS.md

Ralph automates iterative development by orchestrating Claude CLI to work through TODO lists one task at a time, tracking progress and auto-committing changes.

## Commands

```bash
# Run until all tasks complete (Claude CLI)
./ralph.sh <plan-dir>

# Run with max iterations
./ralph.sh <plan-dir> 10

# Use specific model (haiku, sonnet, opus)
./ralph.sh --model sonnet <plan-dir>

# Use OpenCode CLI with a provider
./ralph.sh --cli opencode --provider anthropic <plan-dir>
./ralph.sh --cli opencode --provider github-copilot --model sonnet <plan-dir>
./ralph.sh --cli opencode --provider openrouter <plan-dir>  # Uses free GLM-4.7

# Lint before committing
shellcheck ralph.sh
```

## Architecture

Single bash script (`ralph.sh`) with these sections:
- **CONFIGURATION**: Constants, global state, per-iteration state
- **FUNCTIONS**: Logging, timer, dependency checks, API calls, metrics
- **MAIN LOOP**: Read TODO → Call Claude → Extract metrics → Commit → Repeat

Key functions:
- `call_claude_api()` - Calls Claude CLI with retry logic and timeout
- `call_opencode_api()` - Calls OpenCode CLI with retry logic
- `extract_iteration_metrics()` - Parses Claude JSON response for metrics
- `extract_iteration_metrics_opencode()` - Parses OpenCode JSONL for metrics
- `create_plan_branch()` - Creates/checks out `ralph/<plan-name>` branch
- `commit_changes()` - Auto-commits with task name as message

Input/Output:
- Input: `<plan-dir>/TODO.md` (checkbox format)
- Output (timestamped per model):
  - `<plan-dir>/YYYY-MM-DD_HH-MM-SS_model_TODO.md` (snapshot)
  - `<plan-dir>/YYYY-MM-DD_HH-MM-SS_model_progress.txt`
  - `<plan-dir>/YYYY-MM-DD_HH-MM-SS_model_ralph_metrics.jsonl`

## Code Style

- Use `[[ ]]` for all test conditions (not `[ ]`)
- Use `==` for string comparison inside `[[ ]]`
- Prefix per-iteration variables with `ITERATION_`
- Prefix aggregate metrics with `TOTAL_`
- Use helper functions for repeated patterns: `print_separator()`, `require_command()`, `log_stderr_file()`

## Key Patterns

```bash
# Logging
log_error "message"   # Red, goes to stderr
log_warn "message"    # Yellow
log_info "message"    # Blue
log_success "message" # Green

# Dependency check
require_command jq || missing_deps=1
```

## Never Do

- Modify git config (user.name, user.email)
- Change the Claude prompt structure (it expects `@$TODO_SNAPSHOT` and `@$PROGRESS_FILE`)
- Remove `set -euo pipefail`
- Skip shellcheck validation before commits
