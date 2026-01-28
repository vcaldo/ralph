# Ralph - Technical Reference

Comprehensive technical documentation for ralph.sh - an automated iterative development system using Claude. For getting started quickly, see [README.md](README.md).

## Command-Line Interface

### Synopsis

```bash
ralph.sh [OPTIONS] <plan-dir> [iterations]
```

### Options

- `--model <haiku|sonnet|opus>` - Specify which Claude model to use (default: opus)
  - `haiku` - Fast, cost-effective model for simple tasks
  - `sonnet` - Balanced model for general-purpose work
  - `opus` - Most capable model for complex tasks

### Arguments

- `plan-dir` (required) - Directory containing the plan
  - Must contain `TODO.md` file
  - Output files will be created here (`progress.txt`, `ralph_metrics.jsonl`)
  - Trailing slash is optional and will be removed automatically

- `iterations` (optional) - Maximum number of iterations to run
  - Must be a positive integer (1 or greater)
  - If omitted, runs in infinite mode until completion signal received
  - Use for testing or cost control

### Examples

```bash
# Run until complete with default model (opus)
./ralph.sh plans/arena-v2/

# Run max 10 iterations with opus
./ralph.sh plans/arena-v2/ 10

# Run until complete using sonnet
./ralph.sh --model sonnet plans/ml-dashboard/

# Run 20 iterations with haiku
./ralph.sh --model haiku plans/refactor/ 20
```

## Metrics & Monitoring

Ralph tracks comprehensive metrics for each iteration and provides summary statistics.

### Metrics Tracked

**Per-Iteration Metrics:**

- **Duration** - Execution time in seconds
- **Model** - Actual model used for the iteration
- **Stop reason** - How Claude ended the interaction
- **Token counts:**
  - Input tokens
  - Output tokens
  - Cache creation tokens
  - Cache read tokens
  - Total tokens (input + output)
- **Files changed** - Number of files modified in git
- **Success status** - Boolean indicating success/failure
- **Exit code** - Claude CLI exit code

**Aggregate Metrics:**

- Total duration across all iterations
- Total input/output tokens
- Total files changed
- Iteration count
- Success rate percentage
- Average duration per iteration
- Min/max iteration duration
- Cache hit rate

### Output Files

All output files are created in the `<plan-dir>/` directory:

| File | Format | Purpose |
|------|--------|---------|
| `TODO.md` | Markdown | Input task list (required to exist before running) |
| `progress.txt` | Text | Progress log appended by Claude after each iteration |
| `ralph_metrics.jsonl` | JSONL | Detailed per-iteration metrics (one JSON object per line) |

### JSONL Format

The `ralph_metrics.jsonl` file contains one JSON object per line (JSONL format). Each line represents one iteration.

**Schema:**

```json
{
  "iteration": 1,
  "timestamp": "2026-01-16T12:34:56Z",
  "duration_seconds": 45,
  "model": "claude-opus-4-5-20251101",
  "stop_reason": "end_turn",
  "usage": {
    "input_tokens": 12500,
    "output_tokens": 850,
    "cache_creation_tokens": 5000,
    "cache_read_tokens": 10000,
    "total_tokens": 13350
  },
  "files_changed": 3,
  "success": true,
  "exit_code": 0
}
```

**Field descriptions:**

- `iteration` - Iteration number (1-based)
- `timestamp` - ISO 8601 UTC timestamp
- `duration_seconds` - Execution time for this iteration
- `model` - Full model identifier used
- `stop_reason` - Reason Claude stopped (e.g., "end_turn", "max_tokens")
- `usage.input_tokens` - Input tokens consumed
- `usage.output_tokens` - Output tokens generated
- `usage.cache_creation_tokens` - Tokens used to create cache entries
- `usage.cache_read_tokens` - Tokens read from cache
- `usage.total_tokens` - input_tokens + output_tokens
- `files_changed` - Number of files modified (via git diff)
- `success` - true if iteration completed successfully
- `exit_code` - Claude CLI exit code (0 = success)

### Cache Hit Rate Calculation

Cache hit rate shows how effectively prompt caching is working:

```
Cache Hit Rate = (cache_read_tokens / input_tokens) × 100%
```

- Higher percentages indicate better cache utilization
- Displayed as "N/A" if no input tokens
- Shown per-iteration and as overall aggregate

### Iteration Metrics Display

After each iteration, Ralph displays a summary:

```
--- Iteration Metrics ---
Duration: 0m 45s
Model: claude-opus-4-5-20251101
Status: end_turn
Input tokens: 12500
Output tokens: 850
Total tokens: 13350
Cache created: 5000 tokens
Cache read: 10000 tokens (80% hit rate)
Files changed: 3
Success: ✓
```

### Final Summary Statistics

When Ralph completes (or is interrupted), it displays comprehensive summary statistics:

```
==================================================
                  FINAL SUMMARY
==================================================

Iterations:
  Completed:       10 / 20
  Success Rate:    100%

Duration:
  Total:           7m 30s
  Average:         0m 45s per iteration
  Min:             38s
  Max:             52s

Token Usage:
  Total Input:     125000 tokens
  Total Output:    8500 tokens
  Total:           133500 tokens
  Average:         13350 tokens per iteration

Cache Performance:
  Total Created:   50000 tokens
  Total Read:      100000 tokens
  Overall Hit Rate: 80%

Files Changed:
  Total:           30 files
  Average:         3 files per iteration

ℹ  Metrics log saved to: plans/arena-v2/ralph_metrics.jsonl
```

### Analyzing Metrics with jq

Extract useful insights from the JSONL metrics file:

```bash
# Average duration per iteration
jq -s 'map(.duration_seconds) | add/length' ralph_metrics.jsonl

# Total token cost
jq -s 'map(.usage.total_tokens) | add' ralph_metrics.jsonl

# Success rate
jq -s '[.[] | select(.success == true)] | length' ralph_metrics.jsonl

# Find slowest iteration
jq -s 'max_by(.duration_seconds)' ralph_metrics.jsonl

# Cache hit rates per iteration
jq -r '[.iteration, (.usage.cache_read_tokens / .usage.input_tokens * 100 | round)] | @csv' ralph_metrics.jsonl
```

## Git Integration

Ralph requires a git repository and performs several git-related operations.

### Pre-flight Checks

Before starting, Ralph validates:

1. **Repository check** - Verifies you're in a git repository
2. **Uncommitted changes warning** - Warns if working directory has uncommitted changes
3. **Untracked files warning** - Warns if untracked files exist
4. **Detached HEAD check** - Errors if repository is in detached HEAD state

**Failure conditions:**
- Not in a git repository → Exit with error
- Detached HEAD state → Exit with error
- Uncommitted/untracked files → Warning only (continues)

### Git Identity Requirements

Ralph requires git identity to be configured:

```bash
git config user.name
git config user.email
```

If either is missing, Ralph exits with installation instructions.

### Auto-commit Behavior

After each iteration, Ralph automatically commits changes if files were modified:

1. **Checks for changes** - Uses `git status --porcelain`
2. **Stages all changes** - Runs `git add -A`
3. **Creates commit** - Uses task description as commit message
4. **Reports status** - Logs success or failure

**Commit message format:**
- Uses the current task description extracted from TODO.md
- Format: First unchecked task from TODO file (e.g., "Implement user authentication")

### Files Changed Tracking

Ralph counts files changed using `git diff --name-only HEAD`, which shows files modified since the last commit.

## Signal Handling

Ralph implements graceful handling of interruption signals.

### Graceful Interruption

When you press Ctrl+C (SIGINT) or send SIGTERM:

1. **Stops timer** - Cleans up the display timer
2. **Displays warning** - Shows interruption message
3. **Prints summary** - Displays final summary with metrics collected so far
4. **Shows resume instructions** - Provides exact command to continue
5. **Exits cleanly** - Returns exit code 130 (standard for SIGINT)

**Example output:**

```
==================================================
⚠  Script interrupted by user (Ctrl+C)
==================================================

[Final Summary Statistics]

ℹ  Progress file: plans/arena-v2/progress.txt
ℹ  To continue, run: ./ralph.sh plans/arena-v2/
```

### Exit Codes

- `0` - Success (all tasks completed with completion signal)
- `1` - Error (validation failure, dependency missing, API error)
- `130` - Interrupted by user (Ctrl+C / SIGINT)

### Signal Trap

Ralph sets up signal traps for clean shutdown:

```bash
trap 'on_interrupt' SIGINT SIGTERM
```

## Progress Display

Ralph provides real-time visual feedback during execution.

### Color-Coded Output

Ralph uses color-coded symbols for different message types (ralph.sh:59-73):

- `✓` (green) - Success messages
- `✗` (red) - Error messages
- `⚠` (yellow) - Warning messages
- `ℹ` (blue) - Informational messages

### Real-Time Timer

During Claude API calls, Ralph displays an animated timer (ralph.sh:79-118):

```
⠋ Running... 02:15
```

Features:
- Animated spinner (10-frame braille pattern)
- Elapsed time in MM:SS format
- Updates every second
- Automatically clears when operation completes

**Spinner characters:** `⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏` (ralph.sh:53)

### Iteration Header

Each iteration displays a clear header (ralph.sh:684-690):

**Infinite mode:**
```
==================================================
Iteration 5 (unlimited)
==================================================
```

**Finite mode:**
```
==================================================
Iteration 5 / 20
==================================================
```

## Advanced Usage

### Monitoring Progress

Watch progress in real-time using `tail`:

```bash
# Watch progress log
tail -f plans/my-plan/progress.txt

# Watch progress with auto-refresh
watch -n 2 tail -20 plans/my-plan/progress.txt
```

### Resuming Interrupted Runs

Ralph is designed to be resumable. If interrupted:

1. Ralph shows the exact command to resume
2. Claude reads the existing `progress.txt` to understand what's been done
3. Claude consults `TODO.md` to see remaining tasks
4. Execution continues from where it left off

**Important:** The same `plan-dir` preserves all state.

### Completion Signal

Claude signals task completion by outputting (ralph.sh:731, 772, 843):

```xml
<promise>COMPLETE</promise>
```

When Ralph detects this signal:
1. Stops iteration immediately (doesn't continue to max iterations)
2. Displays success message
3. Prints final summary
4. Exits with code 0

### Desktop Notifications

If `tt` (terminal-tools) is installed, Ralph sends desktop notifications on completion (ralph.sh:852-854):

```bash
tt notify "Ralph: All tasks complete after 10 iterations"
```

### Infinite Mode Best Practices

When running without iteration limits:

1. **Start with small task lists** - Verify behavior before large runs
2. **Monitor progress** - Use `tail -f` on progress.txt
3. **Set up notifications** - Install `tt` for completion alerts
4. **Trust the completion signal** - Ensure your TODO.md includes completion criteria

### Limited Iterations Best Practices

When specifying a max iteration count:

1. **Use for cost control** - Prevent runaway token usage
2. **Testing new plans** - Validate plan structure with low iteration count
3. **Time-boxed work** - Limit work to specific effort budget
4. **Resume as needed** - Run additional iterations if more work remains

## Troubleshooting

### Dependency Issues

**Problem:** `claude CLI not found`

**Solution:**
```bash
npm install -g @anthropic-ai/claude-code
# Or visit: https://docs.anthropic.com/claude-code
```

**Problem:** `jq not found`

**Solution:**
```bash
# Ubuntu/Debian
sudo apt install jq

# macOS
brew install jq

# Fedora
sudo dnf install jq
```

**Problem:** `Git user.name not configured`

**Solution:**
```bash
git config --global user.name "Your Name"
git config --global user.email "your@email.com"
```

### Git Issues

**Problem:** `Not a git repository`

**Solution:** Initialize a git repository:
```bash
git init
git config user.name "Your Name"
git config user.email "your@email.com"
```

**Problem:** `Repository is in detached HEAD state`

**Solution:** Checkout a branch:
```bash
git checkout -b main  # Create and checkout a new branch
# Or
git checkout main     # Checkout existing branch
```

### File Issues

**Problem:** `TODO.md not found in plan directory`

**Solution:** Create TODO.md in your plan directory:
```bash
mkdir -p plans/my-plan
cp TODO.example.md plans/my-plan/TODO.md
# Edit plans/my-plan/TODO.md with your tasks
```

**Problem:** `Cannot write to progress file or metrics file`

**Solution:** Check directory permissions:
```bash
ls -la plans/my-plan/
chmod u+w plans/my-plan/  # Add write permission
```

### API Issues

**Problem:** API errors or rate limits

**Solution:**
1. Wait and retry (rate limit may reset)
2. Check your API key is valid
3. Verify you have access to the requested model tier
4. Use `--model haiku` for lower-tier access

### Metrics Issues

**Problem:** Invalid JSON response

**Solution:** This indicates a Claude CLI error. Check:
```bash
claude --version  # Verify installation
claude --help     # Test basic functionality
```

**Problem:** Metrics file is corrupted or unreadable

**Solution:**
1. Validate JSONL format:
   ```bash
   jq empty plans/my-plan/ralph_metrics.jsonl
   ```
2. If corrupted, remove and restart:
   ```bash
   rm plans/my-plan/ralph_metrics.jsonl
   ./ralph.sh plans/my-plan/
   ```

### Performance Issues

**Problem:** Very slow iterations

**Possible causes:**
1. Large TODO.md or progress.txt files (high token count)
2. Many files in repository (git operations slow)
3. Network latency to API

**Solutions:**
1. Archive completed tasks from TODO.md periodically
2. Rotate progress.txt for long-running plans
3. Use `--model haiku` for faster (though less capable) iterations

### Task Completion Issues

**Problem:** Ralph doesn't detect completion

**Solution:** Ensure Claude outputs exactly:
```xml
<promise>COMPLETE</promise>
```

Verify by checking the Claude output in the terminal or progress.txt.

**Problem:** Tasks not being marked complete in TODO.md

**Solution:**
1. Check TODO.md format: Tasks must be `- [ ] Task description`
2. Ensure Claude has write permission to TODO.md
3. Review progress.txt to see what Claude is doing

## See Also

- [README.md](README.md) - Quick start guide and overview
- [TODO.example.md](TODO.example.md) - Example task list format
- [ralph.sh](ralph.sh) - Source code
