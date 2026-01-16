# Ralph Script - Quick Reference

Automated iterative development using Claude. Ralph reads tasks from a TODO file, executes work, tracks progress, and makes git commits.

## Quick Start

```bash
# 1. Create a plan directory with TODO.md
mkdir -p plans/my-plan
cp TODO.md.example plans/my-plan/TODO.md
# Edit plans/my-plan/TODO.md with your tasks

# 2. Run Ralph
./scripts/ralph.sh plans/my-plan 99

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

**Tip:** For more interactions, split tasks smaller and increase `iterations`.

The script will look for `TODO.md` in the plan directory and create:
- `progress.txt` - Progress log
- `ralph_metrics.jsonl` - Detailed metrics (JSONL format)

### Examples

```bash
./scripts/ralph.sh plans/arena-v2/ 20
./scripts/ralph.sh plans/ml-dashboard-port-refactor/ 99
./scripts/ralph.sh plans/my-custom-plan/ 99
```

## How Ralph Works

### Per Iteration
1. **Displays iteration number**
2. **Calls Claude** with permission to make edits
3. **Passes** TODO.md and progress.txt for Claude to read
4. **Claude**:
   - Picks the highest-priority unchecked task
   - Works on only that task
   - Updates TODO.md (marks task complete with [x])
   - Appends a summary to progress.txt
5. **Script extracts metrics** from Claude's response
6. **Displays iteration summary**
7. **Checks for completion signal** (`<promise>COMPLETE</promise>`)
8. **Exits early** if complete, otherwise continues

### Exit Conditions
- **Early exit**: When Claude outputs `<promise>COMPLETE</promise>`
- **Normal exit**: When all iterations complete

## Requirements

### Git Configuration
Ralph commits use your git identity:

```bash
git config user.name
git config user.email
```

### Claude CLI
Requires `claude` command to be installed and in PATH:

```bash
which claude
claude --version
```

## Monitoring

```bash
tail -f plans/my-plan/progress.txt
git log --oneline -5
```

## Files Reference

| File | Location | Purpose |
|------|----------|---------|
| `TODO.md` | `<plan-dir>/TODO.md` | Task list (required) |
| `progress.txt` | `<plan-dir>/progress.txt` | Progress log |
| `ralph_metrics.jsonl` | `<plan-dir>/ralph_metrics.jsonl` | Detailed metrics |

