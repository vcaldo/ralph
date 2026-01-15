# Ralph Script - Quick Reference

Automated iterative development using Claude. Ralph reads tasks from a TODO file, executes work, tracks progress, and makes git commits.

## Quick Start

```bash
# 1. Create a TODO.md file with tasks
cp TODO.md.example TODO.md
# Edit TODO.md with your tasks

# 2. Run Ralph
./scripts/ralph.sh 10

# 3. Watch progress
tail -f progress.txt
```

## Usage

### Basic Command
```bash
./ralph.sh <plan-dir> <iterations>
```

### Arguments
- **plan-dir** (required): Directory containing the plan (must have `TODO.md`)
- **iterations** (required): Maximum number of iterations (1+)

The script will look for `TODO.md` in the plan directory and create:
- `progress.txt` - Progress log
- `ralph_metrics.jsonl` - Detailed metrics (JSONL format)

### Examples

**Run 10 iterations on arena-v2 plan**
```bash
./ralph.sh plans/arena-v2/ 10
```

**Run 20 iterations on ml-dashboard plan**
```bash
./ralph.sh plans/ml-dashboard-port-refactor/ 20
```

**Run 5 iterations on any plan directory**
```bash
./ralph.sh plans/my-custom-plan/ 5
```

**Run via make (if target added)**
```bash
make ralph ITERATIONS=10
```

## How Ralph Works

### Per Iteration
1. **Displays iteration number** and separator
2. **Calls Claude** with permission to make edits
3. **Passes** TODO.md and progress.txt for Claude to read
4. **Claude**:
   - Identifies highest-priority incomplete task
   - Works on ONLY that single task
   - Updates TODO.md (marks task complete with [x])
   - Appends summary to progress.txt
5. **Script extracts metrics** from Claude's response (tokens, duration, etc.)
6. **Displays iteration summary** with metrics
7. **Checks for completion signal** (`<promise>COMPLETE</promise>`)
8. **If complete**: Exits immediately with final summary
9. **If incomplete**: Continues to next iteration (up to max)

### Exit Conditions
- **Early exit**: When Claude outputs `<promise>COMPLETE</promise>`
- **Normal exit**: When all iterations complete

## File Formats

### TODO.md Format
Standard markdown with checkbox tasks:

```markdown
# Tasks

## High Priority
- [ ] Feature A
- [ ] Bug fix B

## Medium Priority
- [ ] Feature C

## Completed
- [x] Feature X
```

**Rules**:
- Use `- [ ]` for incomplete tasks
- Use `- [x]` for completed tasks
- Ralph reads unchecked items as work to do
- Organize by priority (high → medium → low)

### progress.txt Format
Freeform log file. Ralph appends entries like:

```
2026-01-14 10:30:00 - Feature A
  Completed: Setup database schema and migrations
  Next: Add API endpoints

2026-01-14 11:15:00 - Bug fix B
  Completed: Fixed race condition in login flow
  Tests: All passing
```

**Format is flexible** - Claude appends what makes sense for each task.

## Requirements

### Git Configuration
Ralph commits use your git identity. Verify it's set:

```bash
# Check current config
git config user.name
git config user.email

# Set global config (if needed)
git config --global user.name "Your Name"
git config --global user.email "your@email.com"

# Set for this repo only
git config user.name "Your Name"
git config user.email "your@email.com"
```

### Claude CLI
Requires `claude` command to be installed and in PATH:

```bash
# Verify Claude is available
which claude
claude --version
```

## Workflow Examples

### Example 1: Arena Mini-App Development
```bash
# Create tasks
cat > TODO.md << 'EOF'
# Arena Mini-App Tasks

## High Priority
- [ ] Implement match lobby screen
- [ ] Implement shop phase screen
- [ ] Implement battle display

## Medium Priority
- [ ] Add animations
- [ ] Polish UI

## Low Priority
- [ ] Accessibility improvements
- [ ] Documentation
EOF

# Run ralph
./scripts/ralph.sh 20

# Check progress
cat progress.txt

# Review commits
git log --oneline -20
```

### Example 2: Bug Fix Sprint
```bash
# Create bug list
cat > bugs.md << 'EOF'
# Critical Bugs

## High Priority
- [ ] Fix API timeout issue
- [ ] Fix race condition in shop
- [ ] Fix HP bar animation

## Medium Priority
- [ ] Fix typo in leaderboard
EOF

# Run ralph on bug list
./scripts/ralph.sh 10 bugs.md bug_progress.txt

# Clean up completed bugs
grep -n "\\[x\\]" bugs.md
```

### Example 3: Feature Development
```bash
# Feature tasks
cat > features.md << 'EOF'
# New Features

## High Priority
- [ ] Dark mode support
- [ ] Offline support
- [ ] Export to CSV
EOF

# Run with monitoring
./scripts/ralph.sh 15 features.md feature_progress.txt &
watch -n 5 "tail -10 feature_progress.txt"
```

## Monitoring & Logs

### Watch Progress in Real-time
```bash
# Terminal 1: Run Ralph
./scripts/ralph.sh 20

# Terminal 2: Monitor progress
tail -f progress.txt

# Terminal 3: Watch git commits
watch -n 2 "git log --oneline -5"
```

### Check Status Between Runs
```bash
# See what's been completed
grep "\\[x\\]" TODO.md

# See what's pending
grep "\\[ \\]" TODO.md

# Check last progress entries
tail -20 progress.txt

# Check recent commits
git log --oneline -10
```

### Auto-Commit Format

Ralph automatically commits changes after each iteration if files were modified. Commits follow this format:

```
ralph: <task description>
```

**Examples:**
```bash
# If the task was "Add check_dependencies() function to ralph.sh"
git log --oneline -1
# Output: abc1234 ralph: Add check_dependencies() function to ralph.sh

# If the task was "Implement Stage 1 retry loop"
git log --oneline -1
# Output: def5678 ralph: Implement Stage 1 retry loop
```

**How it works:**
- Ralph extracts the first unchecked task from TODO.md
- After completing the task, Ralph commits with `ralph: <task>` as the message
- Commits use your git identity (not Claude's)
- No commit is made if no files were changed during the iteration

**Check Ralph commits:**
```bash
# View all Ralph commits in current branch
git log --oneline --grep="^ralph:"

# Count Ralph commits
git log --oneline --grep="^ralph:" | wc -l

# See what files Ralph modified
git log --grep="^ralph:" --stat
```

## Iteration Message Flow

Each Ralph iteration follows a canonical message order. Understanding this flow helps when debugging or monitoring Ralph's progress.

### Canonical Message Order

**Phase 1: Iteration Start**
```
==================================================
Iteration N
==================================================
```

**Phase 2: Model Acquisition**
```
Trying opus...
```
Then one of:
- `✓ opus` - Got requested model
- `✗ got [model], retrying (N/M)...` - Wrong model, will retry
- `✗ opus unavailable, trying alternating strategy...` - Moving to Stage 2

**Phase 3: Model Fallback (if needed)**
Stage 2 alternates between Sonnet and Opus:
- `✓ opus` - Got Opus on retry
- `✓ sonnet (fallback)` - Accepted Sonnet as fallback
- `✗ got [model], retrying (N/M)...` - Still retrying
- Hard failure exits with error message

**Phase 4: Claude's Work Output**
```
[Claude's result text - task completion, explanations, etc.]
```

**Phase 5: Auto-Commit (if files changed)**
```
✓ Committed: ralph: [task description]
```
Or if no changes: `ℹ No changes to commit`

**Phase 6: Iteration Metrics**
```
--- Iteration Metrics ---
Duration: Xm XXs
Model: [model name]
Status: [stop_reason]
Input tokens: XXXXX
Output tokens: XXXXX
Total tokens: XXXXX
Cache created: XXXXX tokens
Cache read: XXXXX tokens (XX% hit rate)
Files changed: X
Success: ✓
```

**Phase 7: Completion Check**
If `<promise>COMPLETE</promise>` found in output:
```
==================================================
✓ All tasks complete, exiting
==================================================
[Final Summary displayed]
```

### Message Source Reference

| Phase | Source Location | Function/Code |
|-------|----------------|---------------|
| Iteration Header | ralph.sh:651-654 | Main loop |
| Model Acquisition | ralph.sh:674-721 | Stage 1 retry |
| Model Fallback | ralph.sh:724-790 | Stage 2 retry |
| Claude Output | ralph.sh:804 | Main loop |
| Auto-Commit | ralph.sh:799-801 | `commit_changes()` |
| Iteration Metrics | ralph.sh:808 | `print_metrics_summary()` |
| Completion | ralph.sh:812-826 | Main loop |

## Metrics & Performance Tracking

Ralph automatically captures detailed metrics for each interaction, helping you understand execution time, token consumption, and cache performance.

### Per-Interaction Metrics List

After each iteration completes, Ralph displays metrics in a simple list format:

**Example output:**
```
[Claude's work output appears here first...]

--- Iteration Metrics ---
Duration: 1m 27s
Model: claude-opus-4-5-20251101
Status: result
Input tokens: 1234
Output tokens: 567
Total tokens: 1801
Cache created: 0 tokens
Cache read: 890 tokens (72% hit rate)
Files changed: 3
Success: ✓
```

**What each metric means:**
- **Duration**: Total time for the interaction (API call + Claude processing)
- **Model**: Which Claude model handled the request (e.g., claude-opus-4-5-20251101)
- **Status**: Response type from Claude (result = successful response, error = failed request)
- **Input Tokens**: Tokens consumed by your task description and context
- **Output Tokens**: Tokens generated in Claude's response
- **Total Tokens**: Sum of input and output tokens for this iteration
- **Cache Created**: Tokens used to create the prompt cache (first run with context)
- **Cache Read**: Tokens read from cached context (subsequent runs, lower cost)
- **Cache Hit Rate**: Percentage of input tokens from cache vs computed
- **Files Changed**: Number of files modified during this iteration
- **Success**: ✓ (success) or ✗ (failed with exit code)

### Final Summary

When Ralph completes all iterations (or early exits), it displays an aggregate summary:

```
==================================================
                  FINAL SUMMARY
==================================================

Iterations:
  Completed:       7 / 10
  Success Rate:    100%

Duration:
  Total:           12m 15s
  Average:         1m 45s per iteration
  Min:             47s
  Max:             2m 31s

Token Usage:
  Total Input:     8,456 tokens
  Total Output:    3,912 tokens
  Total:           12,368 tokens
  Average:         1,767 tokens per iteration

Cache Performance:
  Total Created:   2,340 tokens
  Total Read:      6,234 tokens
  Overall Hit Rate: 42%

Files Changed:
  Total:           21 files
  Average:         3 files per iteration

Cost Estimate (claude-opus-4-5-20251101):
  Input tokens:    $0.025
  Output tokens:   $0.047
  Total:           $0.072

ℹ  Metrics log saved to: ralph_metrics.jsonl
```

### Metrics Log File (ralph_metrics.jsonl)

Ralph saves detailed metrics to `ralph_metrics.jsonl` - one JSON object per line, perfect for analysis:

```json
{"iteration":1,"timestamp":"2026-01-15T10:30:45Z","duration_seconds":87,"model":"claude-opus-4-5-20251101","stop_reason":"result","usage":{"input_tokens":1234,"output_tokens":567,"cache_creation_tokens":0,"cache_read_tokens":890,"total_tokens":1801},"files_changed":3,"success":true,"exit_code":0}
{"iteration":2,"timestamp":"2026-01-15T10:32:22Z","duration_seconds":95,"model":"claude-opus-4-5-20251101","stop_reason":"result","usage":{"input_tokens":1156,"output_tokens":612,"cache_creation_tokens":0,"cache_read_tokens":945,"total_tokens":1768},"files_changed":2,"success":true,"exit_code":0}
```

**Field meanings in JSONL:**
- `iteration`: Iteration number (1-based)
- `timestamp`: ISO 8601 timestamp when interaction completed
- `duration_seconds`: How long the iteration took
- `model`: Claude model name that handled the request
- `stop_reason`: Response type (result = success, error = failure)
- `usage.input_tokens`: Tokens consumed from your context
- `usage.output_tokens`: Tokens generated by Claude
- `usage.cache_creation_tokens`: Tokens used to build cache (first run only)
- `usage.cache_read_tokens`: Tokens read from cache (subsequent runs)
- `usage.total_tokens`: Sum of input and output tokens
- `files_changed`: Number of files modified in git
- `success`: Boolean - true if exit code was 0
- `exit_code`: Process exit code (0 = success)

**Analyzing metrics:**

```bash
# View all metrics in pretty-printed format
cat ralph_metrics.jsonl | jq '.'

# Get average tokens per iteration
cat ralph_metrics.jsonl | jq -s '[.[].usage.total_tokens] | add / length'

# Find slowest iteration
cat ralph_metrics.jsonl | jq -s 'max_by(.duration_seconds)'

# Find fastest iteration
cat ralph_metrics.jsonl | jq -s 'min_by(.duration_seconds)'

# Count successful vs failed iterations
cat ralph_metrics.jsonl | jq -s '[.[] | .success] | group_by(.) | map({success: .[0], count: length})'

# Calculate total cost (Opus pricing: $3.00/MTok input, $12.00/MTok output)
cat ralph_metrics.jsonl | jq -s 'map(.usage | (.input_tokens/1000000)*3.00 + (.output_tokens/1000000)*12.00) | add'

# Find iterations with cache hits
cat ralph_metrics.jsonl | jq '.[] | select(.usage.cache_read_tokens > 0)'

# Show average cache hit rate across all iterations
cat ralph_metrics.jsonl | jq -s '[.[] | .usage.cache_read_tokens] | add as $read | [.[] | .usage.input_tokens] | add as $input | (($read / $input) * 100)'
```

### Dynamic Cost Estimation

Ralph automatically calculates costs based on the **actual Claude model used** in your session, not a hardcoded tier. Cost estimates are shown in the final summary.

**How it works:**
1. Ralph captures the model name from each interaction (e.g., `claude-opus-4-5-20251101`)
2. At the end, it extracts the primary model from the metrics
3. Applies that model's actual pricing to calculate total session cost
4. Shows the model name in the cost estimate header

**Current Model Pricing (per million tokens):**

| Model | Input | Output | Example Cost (1M input + 1M output) |
|-------|-------|--------|-------------------------------------|
| Haiku | $0.80 | $4.00 | $4.80 |
| Sonnet | $3.00 | $12.00 | $15.00 |
| Opus | $15.00 | $45.00 | $60.00 |

**Example output:**
```
Cost Estimate (claude-opus-4-5-20251101):
  Input tokens:    $0.025
  Output tokens:   $0.047
  Total:           $0.072
```

The model name in the header (e.g., `claude-opus-4-5-20251101`) is the actual model that processed your requests during this session, ensuring cost estimates are accurate for your specific usage.

**Manual cost calculation with jq:**

If you want to calculate costs with a specific model's pricing:

```bash
# Calculate with Opus pricing
cat ralph_metrics.jsonl | jq -s 'map(.usage | (.input_tokens/1000000)*15.00 + (.output_tokens/1000000)*45.00) | add'

# Calculate with Haiku pricing
cat ralph_metrics.jsonl | jq -s 'map(.usage | (.input_tokens/1000000)*0.80 + (.output_tokens/1000000)*4.00) | add'

# Calculate with Sonnet pricing
cat ralph_metrics.jsonl | jq -s 'map(.usage | (.input_tokens/1000000)*3.00 + (.output_tokens/1000000)*12.00) | add'
```

### Performance Tips

**Optimize token usage:**
- Keep tasks focused and specific (less context needed)
- Use simpler task descriptions (fewer input tokens)
- Let prompt caching work (higher cache hit rate = lower cost)
- Monitor average tokens per iteration and adjust task complexity

**Monitor duration:**
- If iterations are too slow, consider smaller tasks
- Average duration helps predict total run time
- Cache creation (first run) is slower than cache hits

**Track costs:**
- Review final cost estimate to understand expenses
- Cache performance directly affects costs
- Token usage grows with code complexity and context size

### Metrics File Management

**Keep metrics for analysis:**
```bash
# Archive old metrics before new runs
cp ralph_metrics.jsonl ralph_metrics_2026-01-15.jsonl

# Combine multiple metric files
cat ralph_metrics_*.jsonl > ralph_metrics_all.jsonl
```

**Ignore metrics in git:**
```bash
# Metrics are already ignored (see .gitignore)
git status  # ralph_metrics.jsonl should not appear
```

## Tips & Best Practices

### ✅ Do This
- Keep task descriptions clear and specific
- Organize by priority (high → medium → low)
- Use simple, actionable language
- Add context comments if tasks are complex
- Check git log to verify commits are using your identity
- Save and review progress.txt frequently

### ❌ Avoid This
- Don't give Ralph conflicting or vague tasks
- Don't include too many tasks (start with 5-10)
- Don't modify TODO.md while Ralph is running
- Don't modify progress.txt directly (let Ralph append)
- Don't set iterations too high without monitoring

### 🎯 Optimization Tips
- Start with fewer iterations (5) to test workflow
- Use clear, specific task names
- Group related work in single tasks
- Monitor first run to check quality
- Increase iterations once you see good results

## Graceful Interrupt Handling

Ralph handles Ctrl+C (SIGINT) gracefully:

```bash
./ralph.sh plans/my-plan 20
^C
# Prints:
# ==================================================
# ⚠  Script interrupted by user (Ctrl+C)
# ==================================================
# [Final summary with collected metrics]
# ℹ  Progress file: plans/my-plan/progress.txt
# ℹ  To continue, run: ./ralph.sh plans/my-plan 20
```

**What happens when you press Ctrl+C:**
1. Current iteration is cancelled (Claude process terminated)
2. Final summary displays with metrics from completed iterations
3. Remaining iterations are skipped
4. You're given instructions to resume
5. Exit code is 130 (standard for SIGINT)

**To resume after interruption:**
```bash
./ralph.sh plans/my-plan 20
```

Ralph will continue from where it left off (completed tasks remain marked as `[x]`).

## Troubleshooting

### Script exits immediately
**Check**: Did you set git config?
```bash
git config user.name
git config user.email
```

### No progress appearing
**Check**: Can Ralph write to files?
```bash
ls -l plans/my-plan/
# Should show: TODO.md, progress.txt, ralph_metrics.jsonl
```

### Ralph keeps working on same task
**Check**: Is task properly formatted in TODO.md?
- Use `- [ ]` (with space) for incomplete
- Use `- [x]` for completed
- Check for typos in task names
- Make sure TODO.md is in the plan directory

### Git commits not using correct author
**Check**: Is git configured for this repo?
```bash
git config --list | grep user
# If not set, use: git config user.name "Your Name"
```

### Claude not found error
**Check**: Is Claude CLI installed?
```bash
which claude
claude --version
```

## Integration with Make

### Add to Makefile
```makefile
# Ralph automation
.PHONY: ralph
ralph:
	@bash ./ralph.sh $(PLAN_DIR) $(ITERATIONS)
```

### Usage via make
```bash
make ralph PLAN_DIR=plans/arena-v2 ITERATIONS=10
make ralph PLAN_DIR=plans/ml-dashboard-port-refactor ITERATIONS=20
```

## Advanced Usage

### Parallel tasks (different plan directories)
```bash
# Terminal 1: Bug fixes in one plan
./ralph.sh plans/bug-fixes 10

# Terminal 2: Features in another plan (don't overlap files)
./ralph.sh plans/features 10
```

### Resume from checkpoint
```bash
# First run
./ralph.sh plans/my-plan 10

# Resume (interrupted run continues, completed tasks marked with [x])
./ralph.sh plans/my-plan 10
```

### Custom notification
```bash
# Ralph will use 'tt notify' if available
# Install tt: npm install -g @sanity/notification

# Custom notification setup
function claude() {
  /usr/local/bin/claude "$@"
  notify-send "Claude completed iteration"  # Linux
  # or
  osascript -e 'display notification "Done"'  # macOS
}
```

## Output & Debugging

### Standard output
```
Ralph Automation Script
ℹ  Iterations: 10
ℹ  TODO file: TODO.md
ℹ  Progress file: progress.txt

==================================================
Iteration 1
==================================================

[Claude working...]

[Checking for completion signal...]

==================================================
Iteration 2
==================================================
[...]
```

### Enable bash debug mode
```bash
bash -x ./scripts/ralph.sh 5
```

## Files Reference

| File | Location | Purpose | Created by |
|------|----------|---------|-----------|
| `TODO.md` | `<plan-dir>/TODO.md` | Task list (required) | You |
| `progress.txt` | `<plan-dir>/progress.txt` | Progress log | Ralph (auto-created) |
| `ralph_metrics.jsonl` | `<plan-dir>/ralph_metrics.jsonl` | Detailed metrics (JSONL) | Ralph (auto-created) |
| `ralph.sh` | Repository root | Main script | Provided |
| `RALPH.md` | Repository root | This guide | Provided |

**Note**: `ralph_metrics.jsonl` and `progress.txt` are gitignored by default (see `.gitignore`)

## See Also

- [CLAUDE.md](../CLAUDE.md) - Project overview
- [Makefile](../Makefile) - Build targets
- [scripts/](../scripts/) - Other utility scripts

## Contributing

To improve Ralph:
1. Test with different task types
2. Report edge cases or bugs
3. Share workflow tips with team
4. Suggest enhancements (see plan file)

---

**Ralph** - Automate your development workflow with Claude
