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

- `--poorman` - Enable poorman mode (accepts any model returned, no verification)

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

# Run 20 iterations with haiku in poorman mode
./ralph.sh --model haiku --poorman plans/refactor/ 20

# Combined options
./ralph.sh --model sonnet --poorman plans/arena-v2/
```

## Operation Modes

### Normal Mode (Default)

In normal mode, Ralph enforces strict model verification with retry logic:

- Requests the specified model (`--model` flag, default: opus)
- Verifies the returned model matches the requested model
- Retries with exponential backoff if wrong model received (up to 10 attempts)
- Fails fast on API errors or invalid JSON responses
- Ensures consistent model usage across all iterations

**Use when:** You need guaranteed model consistency and quality (recommended for production work).

**Retry behavior:** ralph.sh:738-820
**Model verification:** ralph.sh:789-820

### Poorman Mode

In poorman mode (`--poorman` flag), Ralph accepts whatever model is returned:

- Requests the specified model but accepts any model
- Single attempt only - no retries for model mismatches
- Still fails fast on API errors or invalid JSON
- Useful when model availability is limited or cost is a concern

**Use when:** Testing, development, or when any model will suffice.

**Implementation:** ralph.sh:708-736

## Retry & Backoff Strategy

Ralph implements exponential backoff for model verification in normal mode.

### Retry Configuration

- **Maximum retries:** 10 attempts (ralph.sh:46)
- **Initial delay:** 5 seconds (ralph.sh:47)
- **Maximum delay:** 600 seconds / 10 minutes (ralph.sh:48)
- **Strategy:** Exponential backoff with cap

### Backoff Delays

Retry delays double with each attempt until reaching the cap:

| Attempt | Delay   |
|---------|---------|
| 1       | 5s      |
| 2       | 10s     |
| 3       | 20s     |
| 4       | 40s     |
| 5       | 80s     |
| 6       | 160s    |
| 7       | 320s    |
| 8       | 600s    |
| 9       | 600s    |
| 10      | 600s    |

**Implementation:** ralph.sh:122-137

### Countdown Display

During retry backoff, Ralph displays an animated countdown timer showing:
- Spinner animation
- Minutes and seconds remaining
- Current retry attempt number

**Implementation:** ralph.sh:140-162

### Fail-Fast Scenarios

Ralph immediately exits (no retries) on:

1. **API errors** - Non-zero exit code from Claude CLI (ralph.sh:776-781)
2. **Invalid JSON** - Malformed response that cannot be parsed (ralph.sh:784-787)
3. **Exhausted retries** - All 10 retry attempts failed (ralph.sh:807-811)

## Metrics & Monitoring

Ralph tracks comprehensive metrics for each iteration and provides summary statistics.

### Metrics Tracked

**Per-Iteration Metrics:**

- **Duration** - Execution time in seconds (ralph.sh:349)
- **Model** - Actual model used for the iteration (ralph.sh:367)
- **Stop reason** - How Claude ended the interaction (ralph.sh:368)
- **Token counts:**
  - Input tokens (ralph.sh:369)
  - Output tokens (ralph.sh:370)
  - Cache creation tokens (ralph.sh:371)
  - Cache read tokens (ralph.sh:372)
  - Total tokens (input + output) (ralph.sh:373)
- **Files changed** - Number of files modified in git (ralph.sh:376)
- **Success status** - Boolean indicating success/failure (ralph.sh:379-382)
- **Exit code** - Claude CLI exit code (ralph.sh:39)

**Aggregate Metrics:**

- Total duration across all iterations (ralph.sh:388)
- Total input/output tokens (ralph.sh:389-390)
- Total files changed (ralph.sh:391)
- Iteration count (ralph.sh:392)
- Success rate percentage (ralph.sh:468-472)
- Average duration per iteration (ralph.sh:476-480)
- Min/max iteration duration (ralph.sh:483-484)
- Cache hit rate (ralph.sh:497)

### Output Files

All output files are created in the `<plan-dir>/` directory:

| File | Format | Purpose |
|------|--------|---------|
| `TODO.md` | Markdown | Input task list (required to exist before running) |
| `progress.txt` | Text | Progress log appended by Claude after each iteration |
| `ralph_metrics.jsonl` | JSONL | Detailed per-iteration metrics (one JSON object per line) |

**File validation:** ralph.sh:600-604, 666-669

### JSONL Format

The `ralph_metrics.jsonl` file contains one JSON object per line (JSONL format). Each line represents one iteration.

**Schema (ralph.sh:395-431):**

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

**Implementation:** ralph.sh:237-250, 438, 497

### Iteration Metrics Display

After each iteration, Ralph displays a summary (ralph.sh:433-458):

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

When Ralph completes (or is interrupted), it displays comprehensive summary statistics (ralph.sh:460-535):

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

Before starting, Ralph validates (ralph.sh:252-280):

1. **Repository check** - Verifies you're in a git repository
2. **Uncommitted changes warning** - Warns if working directory has uncommitted changes
3. **Untracked files warning** - Warns if untracked files exist
4. **Detached HEAD check** - Errors if repository is in detached HEAD state

**Failure conditions:**
- Not in a git repository → Exit with error
- Detached HEAD state → Exit with error
- Uncommitted/untracked files → Warning only (continues)

### Git Identity Requirements

Ralph requires git identity to be configured (ralph.sh:198-213):

```bash
git config user.name
git config user.email
```

If either is missing, Ralph exits with installation instructions.

### Auto-commit Behavior

After each iteration, Ralph automatically commits changes if files were modified (ralph.sh:828-831):

1. **Checks for changes** - Uses `git status --porcelain` (ralph.sh:289)
2. **Stages all changes** - Runs `git add -A` (ralph.sh:295)
3. **Creates commit** - Uses task description as commit message (ralph.sh:301)
4. **Reports status** - Logs success or failure

**Commit message format (ralph.sh:286, 830):**
- Uses the current task description extracted from TODO.md
- Format: First unchecked task from TODO file (e.g., "Implement user authentication")

### Files Changed Tracking

Ralph counts files changed using `git diff --name-only HEAD` (ralph.sh:376), which shows files modified since the last commit.

## Signal Handling

Ralph implements graceful handling of interruption signals.

### Graceful Interruption

When you press Ctrl+C (SIGINT) or send SIGTERM (ralph.sh:314-338):

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
- `1` - Error (validation failure, dependency missing, API error, retry exhausted)
- `130` - Interrupted by user (Ctrl+C / SIGINT)

### Signal Trap

Ralph sets up signal traps for clean shutdown (ralph.sh:338):

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

### Retry Countdown

During retry backoff, Ralph displays a countdown timer (ralph.sh:140-162):

```
⠋ Waiting... 05:00 remaining
```

Shows:
- Animated spinner
- Time remaining in MM:SS format
- Updates every second

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

### Model Status Display

Ralph shows model status after API calls:

**Normal mode success:**
```
✓ opus
```

**Poorman mode:**
```
✓ claude-sonnet-4-5-20250929 (poorman mode - any model accepted)
```

**Normal mode retry:**
```
⚠  Got sonnet instead of opus
ℹ  Retrying in 5s (attempt 1/10)
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

### Model Issues

**Problem:** `Requested opus but got sonnet` (with retry failures)

**Solution:**
1. Use `--poorman` mode to accept any model:
   ```bash
   ./ralph.sh --poorman plans/my-plan/
   ```
2. Or request a different model:
   ```bash
   ./ralph.sh --model sonnet plans/my-plan/
   ```
3. Check your API tier/quota for the requested model

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
