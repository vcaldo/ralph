# Ralph Script - Quick Reference

Automated iterative development using Claude. Ralph reads tasks from a TODO file, executes work, tracks progress, and makes git commits.

## Quick Start

```bash
# 1. Create a plan directory with TODO.md
mkdir -p plans/my-plan
cp TODO.md.example plans/my-plan/TODO.md
# Edit plans/my-plan/TODO.md with your tasks

# 2. Run Ralph
./scripts/ralph.sh plans/my-plan 10

# 3. Watch progress
tail -f plans/my-plan/progress.txt
```

## Usage

### Basic Command
```bash
./scripts/ralph.sh <plan-dir> <iterations>
```

### Optional Flags
Run `./scripts/ralph.sh --help` to see supported flags for this version.

### Arguments
- **plan-dir** (required): Directory containing the plan (must have `TODO.md`)
- **iterations** (required): Maximum number of iterations (1+)

The script will look for `TODO.md` in the plan directory and create:
- `progress.txt` - Progress log
- `ralph_metrics.jsonl` - Detailed metrics (JSONL format)

### Examples

**Run 10 iterations on arena-v2 plan**
```bash
./scripts/ralph.sh plans/arena-v2/ 10
```

**Run 20 iterations on ml-dashboard plan**
```bash
./scripts/ralph.sh plans/ml-dashboard-port-refactor/ 20
```

**Run 5 iterations on any plan directory**
```bash
./scripts/ralph.sh plans/my-custom-plan/ 5
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

## Workflow Examples

### Example 1: Arena Mini-App Development
```bash
# Create tasks
cat > plans/arena/TODO.md << 'EOF'
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
./scripts/ralph.sh plans/arena 20

# Check progress
cat plans/arena/progress.txt

# Review commits
git log --oneline -20
```

### Example 2: Bug Fix Sprint
```bash
# Create bug list
cat > plans/bugs/TODO.md << 'EOF'
# Critical Bugs

## High Priority
- [ ] Fix API timeout issue
- [ ] Fix race condition in shop
- [ ] Fix HP bar animation

## Medium Priority
- [ ] Fix typo in leaderboard
EOF

# Run ralph
./scripts/ralph.sh plans/bugs 10

# Clean up completed bugs
grep -n "\\[x\\]" plans/bugs/TODO.md
```

### Example 3: Feature Development
```bash
# Feature tasks
cat > plans/features/TODO.md << 'EOF'
# New Features

## High Priority
- [ ] Dark mode support
- [ ] Offline support
- [ ] Export to CSV
EOF

# Run with monitoring
./scripts/ralph.sh plans/features 15 &
watch -n 5 "tail -10 plans/features/progress.txt"
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

Messages vary by version/flags, but generally indicate model selection, retries, or fallbacks.

**Phase 3: Claude's Work Output**
```
[Claude's result text - task completion, explanations, etc.]
```

**Phase 4: Auto-Commit (if files changed)**
```
✓ Committed: ralph: [task description]
```
Or if no changes: `ℹ No changes to commit`

**Phase 5: Iteration Metrics**
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

**Phase 6: Completion Check**
If `<promise>COMPLETE</promise>` found in output:
```
==================================================
✓ All tasks complete, exiting
==================================================
[Final Summary displayed]
```

### Message Source Reference

See `scripts/ralph.sh` for the current message flow and function names.

## Metrics & Performance Tracking

Ralph automatically captures detailed metrics for each interaction, helping you understand execution time, token consumption, and cache performance.

### Per-Interaction Metrics List

After each iteration completes, Ralph displays metrics in a simple list format:

**Example output:**
```
[Claude's work output appears here first...]

--- Iteration Metrics ---
Duration: 1m 27s
Model: [current model]
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
- **Model**: Which Claude model handled the request
- **Status**: Response type from Claude (result = successful response, error = failed request)
- **Input Tokens**: Tokens consumed by your task description and context
- **Output Tokens**: Tokens generated in Claude's response
- **Total Tokens**: Sum of input and output tokens for this iteration
- **Cache Created**: Tokens used to create the prompt cache (first run with context)
- **Cache Read**: Tokens read from cached context (subsequent runs)
- **Cache Hit Rate**: Percentage of input tokens from cache vs computed
- **Files Changed**: Number of files modified during this iteration
- **Success**: ✓ (success) or ✗ (failed with exit code)

### Metrics Log File (ralph_metrics.jsonl)

Ralph saves detailed metrics to `ralph_metrics.jsonl` - one JSON object per line, perfect for analysis:

```json
{"iteration":1,"timestamp":"2026-01-15T10:30:45Z","duration_seconds":87,"model":"<model>","stop_reason":"result","usage":{"input_tokens":1234,"output_tokens":567,"cache_creation_tokens":0,"cache_read_tokens":890,"total_tokens":1801},"files_changed":3,"success":true,"exit_code":0}
{"iteration":2,"timestamp":"2026-01-15T10:32:22Z","duration_seconds":95,"model":"<model>","stop_reason":"result","usage":{"input_tokens":1156,"output_tokens":612,"cache_creation_tokens":0,"cache_read_tokens":945,"total_tokens":1768},"files_changed":2,"success":true,"exit_code":0}
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

# Find iterations with cache hits
cat ralph_metrics.jsonl | jq '.[] | select(.usage.cache_read_tokens > 0)'

# Show average cache hit rate across all iterations
cat ralph_metrics.jsonl | jq -s '[.[] | .usage.cache_read_tokens] | add as $read | [.[] | .usage.input_tokens] | add as $input | (($read / $input) * 100)'
```

### Performance Tips

**Optimize token usage:**
- Keep tasks focused and specific (less context needed)
- Use simpler task descriptions (fewer input tokens)
- Let prompt caching work (higher cache hit rate)
- Monitor average tokens per iteration and adjust task complexity

**Monitor duration:**
- If iterations are too slow, consider smaller tasks
- Average duration helps predict total run time
- Cache creation (first run) is slower than cache hits

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
- Use `--poorman` for cheaper runs when model choice isn't critical

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
