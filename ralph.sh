#!/bin/bash
# Ralph - Automated iterative development using Claude
# Reads tasks from a TODO file, executes work, tracks progress, and commits changes

set -euo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Metrics tracking variables (METRICS_LOG set after PLAN_DIR is validated)
METRICS_LOG=""
TOTAL_DURATION=0
TOTAL_INPUT_TOKENS=0
TOTAL_OUTPUT_TOKENS=0
TOTAL_FILES_CHANGED=0
INTERACTION_COUNT=0

# Per-iteration metrics
ITERATION_DURATION=0
ITERATION_START=0
ITERATION_MODEL="unknown"
ITERATION_STOP_REASON="unknown"
ITERATION_INPUT_TOKENS=0
ITERATION_OUTPUT_TOKENS=0
ITERATION_CACHE_CREATE_TOKENS=0
ITERATION_CACHE_READ_TOKENS=0
ITERATION_TOTAL_TOKENS=0
ITERATION_FILES_CHANGED=0
ITERATION_SUCCESS="true"
CLAUDE_EXIT_CODE=0

# Model retry configuration
REQUESTED_MODEL="opus"
FALLBACK_MODEL="sonnet"
LAST_RESORT_MODEL="haiku"
INITIAL_OPUS_RETRIES=12    # Try Opus first
ALTERNATE_RETRIES=24       # Then alternate between Sonnet and Opus
HAIKU_RETRIES=3            # Fail fast - if Haiku is unavailable, API has major issues
RETRY_DELAY=30             # Fixed 30-second interval
POORMAN_MODE=false         # Skip retry logic, try sonnet once and accept any model

# Model pricing (per million tokens) - easy to update when prices change
HAIKU_INPUT_PRICE=0.80
HAIKU_OUTPUT_PRICE=4.00
SONNET_INPUT_PRICE=3.00
SONNET_OUTPUT_PRICE=12.00
OPUS_INPUT_PRICE=15.00
OPUS_OUTPUT_PRICE=45.00

# Timer/chronograph configuration
TIMER_PID=""
TIMER_START_TIME=0
SPINNER_CHARS='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'

# =============================================================================
# FUNCTIONS
# =============================================================================

log_error() {
    echo -e "${RED}✗${NC}  $1" >&2
}

log_success() {
    echo -e "${GREEN}✓${NC}  $1"
}

log_info() {
    echo -e "${BLUE}ℹ${NC}  $1"
}

log_warn() {
    echo -e "${YELLOW}⚠${NC}  $1"
}

# =============================================================================
# TIMER/CHRONOGRAPH FUNCTIONS
# =============================================================================

# Start a background timer that displays elapsed time with spinner
# Call stop_timer() when the timed operation completes
start_timer() {
    TIMER_START_TIME=$(date +%s)

    # Start background process that updates display every second
    (
        local i=0
        local spinner_len=${#SPINNER_CHARS}
        local start_time=$TIMER_START_TIME

        while true; do
            local now=$(date +%s)
            local elapsed=$((now - start_time))
            local mins=$((elapsed / 60))
            local secs=$((elapsed % 60))
            local char="${SPINNER_CHARS:$((i % spinner_len)):1}"

            # Use carriage return to overwrite line, ANSI codes for color
            printf "\r${CYAN}%s${NC} Running... %02d:%02d" "$char" "$mins" "$secs"

            i=$((i + 1))
            sleep 1
        done
    ) &
    TIMER_PID=$!
}

# Stop the timer and clean up the display line
stop_timer() {
    if [[ -n "$TIMER_PID" ]]; then
        # Kill the background timer process
        kill "$TIMER_PID" 2>/dev/null || true
        wait "$TIMER_PID" 2>/dev/null || true
        TIMER_PID=""
    fi

    # Clear the timer line using ANSI escape sequence
    printf "\r\033[K"
}

# =============================================================================
# DEPENDENCY CHECKS
# =============================================================================

# Check that all required dependencies are available
# Returns 0 if all dependencies are present, 1 otherwise
check_dependencies() {
    local missing_deps=0

    # Check for claude CLI
    if ! command -v claude &> /dev/null; then
        log_error "claude CLI not found"
        echo "  Install: npm install -g @anthropic-ai/claude-code"
        echo "  Or visit: https://docs.anthropic.com/claude-code"
        missing_deps=1
    fi

    # Check for jq
    if ! command -v jq &> /dev/null; then
        log_error "jq not found"
        echo "  Install (Ubuntu/Debian): sudo apt install jq"
        echo "  Install (macOS): brew install jq"
        echo "  Install (Fedora): sudo dnf install jq"
        missing_deps=1
    fi

    # Check for git
    if ! command -v git &> /dev/null; then
        log_error "git not found"
        echo "  Install (Ubuntu/Debian): sudo apt install git"
        echo "  Install (macOS): brew install git"
        echo "  Install (Fedora): sudo dnf install git"
        missing_deps=1
    else
        # Git is available, check for identity configuration
        local git_user git_email
        git_user=$(git config user.name 2>/dev/null || echo "")
        git_email=$(git config user.email 2>/dev/null || echo "")

        if [[ -z "$git_user" ]]; then
            log_error "Git user.name not configured"
            echo "  Run: git config --global user.name \"Your Name\""
            missing_deps=1
        fi

        if [[ -z "$git_email" ]]; then
            log_error "Git user.email not configured"
            echo "  Run: git config --global user.email \"your@email.com\""
            missing_deps=1
        fi
    fi

    if [[ $missing_deps -eq 1 ]]; then
        echo ""
        log_error "Missing dependencies - please install the above before running Ralph"
        return 1
    fi

    return 0
}

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

# Format duration in seconds to "XmYYs" format
format_duration() {
    local total_seconds=$1
    local minutes=$((total_seconds / 60))
    local seconds=$((total_seconds % 60))
    printf "%dm %02ds" "$minutes" "$seconds"
}

# Calculate cache hit rate percentage
# Parameters: cache_read_tokens, input_tokens
# Returns: "N/A" if no input tokens, or "XX%" format
calculate_cache_hit_rate() {
    local cache_read=$1
    local input_tokens=$2

    if [[ $input_tokens -gt 0 ]]; then
        local hit_rate=$(( (cache_read * 100) / input_tokens ))
        echo "${hit_rate}%"
    else
        echo "N/A"
    fi
}

# Check git repository state before starting
# Ensures clean working directory and valid branch
check_git_state() {
    # Check if we're in a git repository
    if ! git rev-parse --git-dir > /dev/null 2>&1; then
        log_error "Not a git repository. Ralph requires a git repository."
        return 1
    fi

    # Check for uncommitted changes
    if ! git diff-index --quiet HEAD --; then
        log_warn "Working directory has uncommitted changes"
        log_warn "Ralph may create new commits that include these changes"
    fi

    # Check for untracked files
    if [[ -n "$(git ls-files --others --exclude-standard)" ]]; then
        log_warn "Working directory has untracked files"
    fi

    # Check if in detached HEAD state
    if ! git symbolic-ref -q HEAD > /dev/null 2>&1; then
        log_error "Repository is in detached HEAD state"
        log_error "Please checkout a branch before running Ralph"
        return 1
    fi

    return 0
}

# Commit changes made during an iteration
# Parameters: commit_message - The commit message to use
# Returns: 0 if commit succeeded or no changes, 1 if commit failed
commit_changes() {
    local commit_message="$1"

    # Check if there are any changes to commit
    if [[ -z "$(git status --porcelain)" ]]; then
        log_info "No changes to commit"
        return 0
    fi

    # Stage all changes
    if ! git add -A; then
        log_error "Failed to stage changes"
        return 1
    fi

    # Execute commit
    if git commit -m "$commit_message"; then
        log_success "Committed: $commit_message"
        return 0
    else
        log_error "Failed to commit changes"
        return 1
    fi
}

# =============================================================================
# SIGNAL HANDLING (Graceful Interrupt)
# =============================================================================

on_interrupt() {
    # Stop timer if running to clean up display
    stop_timer

    echo ""
    echo "=================================================="
    log_warn "Script interrupted by user (Ctrl+C)"
    echo "=================================================="

    # Print final summary with metrics collected so far
    print_final_summary

    log_info "Progress file: $PROGRESS_FILE"
    log_info "To continue, run: $0 $PLAN_DIR $ITERATIONS"

    # Exit with standard signal code for SIGINT
    exit 130
}

# Set up signal trap for graceful interruption
trap 'on_interrupt' SIGINT SIGTERM

# =============================================================================
# PRICING FUNCTIONS
# =============================================================================

# Get pricing for a Claude model
# Returns: "input_price output_price" (per million tokens)
get_model_pricing() {
    local model="$1"

    # Determine model tier from model name
    if [[ "$model" =~ haiku ]]; then
        echo "$HAIKU_INPUT_PRICE $HAIKU_OUTPUT_PRICE"
    elif [[ "$model" =~ sonnet ]]; then
        echo "$SONNET_INPUT_PRICE $SONNET_OUTPUT_PRICE"
    elif [[ "$model" =~ opus ]]; then
        echo "$OPUS_INPUT_PRICE $OPUS_OUTPUT_PRICE"
    else
        # Default to Haiku if model tier can't be determined
        echo "$HAIKU_INPUT_PRICE $HAIKU_OUTPUT_PRICE"
    fi
}

# Get all unique models used in this session from metrics log
get_session_models() {
    if [[ ! -f "$METRICS_LOG" ]]; then
        echo "unknown"
        return
    fi

    # Get all unique models from metrics log and join with comma
    jq -r '.model // "unknown"' "$METRICS_LOG" 2>/dev/null | sort -u | tr '\n' ',' | sed 's/,$//'
}

# Calculate accurate cost from metrics log by summing per-iteration costs
# Returns: "input_cost output_cost total_cost" with proper formatting
calculate_accurate_cost() {
    if [[ ! -f "$METRICS_LOG" ]]; then
        echo "0.000 0.000 0.000"
        return
    fi

    # Use jq to iterate through each iteration in metrics log and sum costs per model
    local result=$(jq -r \
        --arg haiku_in "$HAIKU_INPUT_PRICE" \
        --arg haiku_out "$HAIKU_OUTPUT_PRICE" \
        --arg sonnet_in "$SONNET_INPUT_PRICE" \
        --arg sonnet_out "$SONNET_OUTPUT_PRICE" \
        --arg opus_in "$OPUS_INPUT_PRICE" \
        --arg opus_out "$OPUS_OUTPUT_PRICE" \
        'def get_tier:
            if . | test("haiku"; "i") then "haiku"
            elif . | test("sonnet"; "i") then "sonnet"
            elif . | test("opus"; "i") then "opus"
            else "haiku" end;

        def get_prices:
            if . == "haiku" then {input: ($haiku_in | tonumber), output: ($haiku_out | tonumber)}
            elif . == "sonnet" then {input: ($sonnet_in | tonumber), output: ($sonnet_out | tonumber)}
            elif . == "opus" then {input: ($opus_in | tonumber), output: ($opus_out | tonumber)}
            else {input: ($haiku_in | tonumber), output: ($haiku_out | tonumber)} end;

        # Calculate cost per iteration
        map(
            (.model | get_tier) as $tier |
            ((.usage.input_tokens / 1000000) * ($tier | get_prices | .input)) as $input_cost |
            ((.usage.output_tokens / 1000000) * ($tier | get_prices | .output)) as $output_cost |
            {
                tier: $tier,
                input_cost: $input_cost,
                output_cost: $output_cost
            }
        )
        | {
            total_input: (map(.input_cost) | add // 0),
            total_output: (map(.output_cost) | add // 0)
        }
        | .total_cost = (.total_input + .total_output)
        | "\(.total_input | @text) \(.total_output | @text) \(.total_cost | @text)"
        ' "$METRICS_LOG" 2>/dev/null)

    if [[ -z "$result" ]]; then
        echo "0.000 0.000 0.000"
    else
        echo "$result"
    fi
}

# =============================================================================
# METRICS FUNCTIONS
# =============================================================================

extract_iteration_metrics() {
    local json="$1"
    local start_time="$2"

    # Calculate duration
    ITERATION_DURATION=$((SECONDS - start_time))

    # Validate JSON output
    if ! echo "$json" | jq empty 2>/dev/null; then
        log_warn "Invalid JSON response, using default metrics"
        ITERATION_MODEL="unknown"
        ITERATION_STOP_REASON="parse_error"
        ITERATION_INPUT_TOKENS=0
        ITERATION_OUTPUT_TOKENS=0
        ITERATION_CACHE_CREATE_TOKENS=0
        ITERATION_CACHE_READ_TOKENS=0
        ITERATION_TOTAL_TOKENS=0
        ITERATION_FILES_CHANGED=0
        ITERATION_SUCCESS="false"
        return 1
    fi

    # Extract metrics from JSON with defaults
    ITERATION_MODEL=$(echo "$json" | jq -r '.modelUsage | keys[0] // "unknown"')
    ITERATION_STOP_REASON=$(echo "$json" | jq -r '.type // "unknown"')
    ITERATION_INPUT_TOKENS=$(echo "$json" | jq -r '.usage.input_tokens // 0')
    ITERATION_OUTPUT_TOKENS=$(echo "$json" | jq -r '.usage.output_tokens // 0')
    ITERATION_CACHE_CREATE_TOKENS=$(echo "$json" | jq -r '.usage.cache_creation_input_tokens // 0')
    ITERATION_CACHE_READ_TOKENS=$(echo "$json" | jq -r '.usage.cache_read_input_tokens // 0')
    ITERATION_TOTAL_TOKENS=$((ITERATION_INPUT_TOKENS + ITERATION_OUTPUT_TOKENS))

    # Calculate files changed (count modified files in git)
    ITERATION_FILES_CHANGED=$(git diff --name-only HEAD 2>/dev/null | wc -l)

    # Determine success status
    ITERATION_SUCCESS="true"
    if [[ $CLAUDE_EXIT_CODE -ne 0 ]]; then
        ITERATION_SUCCESS="false"
    fi

    # Append to metrics log (JSONL format)
    append_metrics_log

    # Update running totals
    TOTAL_DURATION=$((TOTAL_DURATION + ITERATION_DURATION))
    TOTAL_INPUT_TOKENS=$((TOTAL_INPUT_TOKENS + ITERATION_INPUT_TOKENS))
    TOTAL_OUTPUT_TOKENS=$((TOTAL_OUTPUT_TOKENS + ITERATION_OUTPUT_TOKENS))
    TOTAL_FILES_CHANGED=$((TOTAL_FILES_CHANGED + ITERATION_FILES_CHANGED))
    INTERACTION_COUNT=$((INTERACTION_COUNT + 1))
}

append_metrics_log() {
    # Get ISO 8601 timestamp
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Build JSON object using jq for proper escaping
    jq -n \
        --arg iteration "$((INTERACTION_COUNT + 1))" \
        --arg timestamp "$timestamp" \
        --arg duration "$ITERATION_DURATION" \
        --arg model "$ITERATION_MODEL" \
        --arg stop_reason "$ITERATION_STOP_REASON" \
        --arg input_tokens "$ITERATION_INPUT_TOKENS" \
        --arg output_tokens "$ITERATION_OUTPUT_TOKENS" \
        --arg cache_create "$ITERATION_CACHE_CREATE_TOKENS" \
        --arg cache_read "$ITERATION_CACHE_READ_TOKENS" \
        --arg total_tokens "$ITERATION_TOTAL_TOKENS" \
        --arg files_changed "$ITERATION_FILES_CHANGED" \
        --arg success "$ITERATION_SUCCESS" \
        --arg exit_code "$CLAUDE_EXIT_CODE" \
        '{
            iteration: ($iteration | tonumber),
            timestamp: $timestamp,
            duration_seconds: ($duration | tonumber),
            model: $model,
            stop_reason: $stop_reason,
            usage: {
                input_tokens: ($input_tokens | tonumber),
                output_tokens: ($output_tokens | tonumber),
                cache_creation_tokens: ($cache_create | tonumber),
                cache_read_tokens: ($cache_read | tonumber),
                total_tokens: ($total_tokens | tonumber)
            },
            files_changed: ($files_changed | tonumber),
            success: ($success == "true"),
            exit_code: ($exit_code | tonumber)
        }' >> "$METRICS_LOG" || log_warn "Failed to write metrics to log file"
}

print_metrics_summary() {
    # Format duration (convert seconds to minutes:seconds)
    local duration_str=$(format_duration "$ITERATION_DURATION")

    # Calculate cache hit rate
    local cache_hit_rate=$(calculate_cache_hit_rate "$ITERATION_CACHE_READ_TOKENS" "$ITERATION_INPUT_TOKENS")

    # Status icon
    local status_icon="✓"
    if [[ "$ITERATION_SUCCESS" == "false" ]]; then
        status_icon="✗"
    fi

    # Print simple list format (no box borders)
    echo "--- Iteration Metrics ---"
    echo "Duration: $duration_str"
    echo "Model: $ITERATION_MODEL"
    echo "Status: $ITERATION_STOP_REASON"
    echo "Input tokens: $ITERATION_INPUT_TOKENS"
    echo "Output tokens: $ITERATION_OUTPUT_TOKENS"
    echo "Total tokens: $ITERATION_TOTAL_TOKENS"
    echo "Cache created: $ITERATION_CACHE_CREATE_TOKENS tokens"
    echo "Cache read: $ITERATION_CACHE_READ_TOKENS tokens ($cache_hit_rate hit rate)"
    echo "Files changed: $ITERATION_FILES_CHANGED"
    echo "Success: $status_icon"
}

print_final_summary() {
    echo ""
    echo "=================================================="
    echo "                  FINAL SUMMARY"
    echo "=================================================="
    echo ""

    # Calculate success rate
    local success_count=$(jq -s '[.[] | select(.success == true)] | length' "$METRICS_LOG" 2>/dev/null || echo "0")
    local success_rate=0
    if [[ $INTERACTION_COUNT -gt 0 ]]; then
        success_rate=$(( (success_count * 100) / INTERACTION_COUNT ))
    fi

    # Calculate average duration
    local avg_duration=0
    local avg_duration_str="0m 0s"
    if [[ $INTERACTION_COUNT -gt 0 ]]; then
        avg_duration=$((TOTAL_DURATION / INTERACTION_COUNT))
        avg_duration_str=$(format_duration "$avg_duration")
    fi

    # Calculate min/max duration from JSONL
    local min_duration=$(jq -s 'map(.duration_seconds) | min' "$METRICS_LOG" 2>/dev/null || echo "0")
    local max_duration=$(jq -s 'map(.duration_seconds) | max' "$METRICS_LOG" 2>/dev/null || echo "0")

    # Calculate average tokens
    local avg_tokens=0
    if [[ $INTERACTION_COUNT -gt 0 ]]; then
        avg_tokens=$(( (TOTAL_INPUT_TOKENS + TOTAL_OUTPUT_TOKENS) / INTERACTION_COUNT ))
    fi

    # Calculate total cache tokens
    local total_cache_create=$(jq -s 'map(.usage.cache_creation_tokens) | add' "$METRICS_LOG" 2>/dev/null || echo "0")
    local total_cache_read=$(jq -s 'map(.usage.cache_read_tokens) | add' "$METRICS_LOG" 2>/dev/null || echo "0")

    # Calculate overall cache hit rate
    local cache_hit_rate=$(calculate_cache_hit_rate "$total_cache_read" "$TOTAL_INPUT_TOKENS")

    # Format total duration
    local total_duration_str=$(format_duration "$TOTAL_DURATION")

    # Get all models used in session
    local session_models=$(get_session_models)

    # Check if multiple models were used
    if [[ "$session_models" == *","* ]]; then
        log_warn "Multiple models detected in session: $session_models"
    fi

    # Calculate accurate cost from per-iteration model usage in metrics log
    read -r input_cost output_cost total_cost <<< $(calculate_accurate_cost)

    # Format costs with consistent precision
    input_cost=$(printf "%.3f" "$input_cost")
    output_cost=$(printf "%.3f" "$output_cost")
    total_cost=$(printf "%.3f" "$total_cost")

    echo "Iterations:"
    echo "  Completed:       $INTERACTION_COUNT / $ITERATIONS"
    echo "  Success Rate:    ${success_rate}%"
    echo ""
    echo "Duration:"
    echo "  Total:           $total_duration_str"
    echo "  Average:         $avg_duration_str per iteration"
    echo "  Min:             ${min_duration}s"
    echo "  Max:             ${max_duration}s"
    echo ""
    echo "Token Usage:"
    printf "  Total Input:     %d tokens\n" "$TOTAL_INPUT_TOKENS"
    printf "  Total Output:    %d tokens\n" "$TOTAL_OUTPUT_TOKENS"
    printf "  Total:           %d tokens\n" "$((TOTAL_INPUT_TOKENS + TOTAL_OUTPUT_TOKENS))"
    printf "  Average:         %d tokens per iteration\n" "$avg_tokens"
    echo ""
    echo "Cache Performance:"
    printf "  Total Created:   %d tokens\n" "$total_cache_create"
    printf "  Total Read:      %d tokens\n" "$total_cache_read"
    echo "  Overall Hit Rate: $cache_hit_rate"
    echo ""
    echo "Files Changed:"
    echo "  Total:           $TOTAL_FILES_CHANGED files"
    if [[ $INTERACTION_COUNT -gt 0 ]]; then
        echo "  Average:         $((TOTAL_FILES_CHANGED / INTERACTION_COUNT)) files per iteration"
    fi
    echo ""
    echo "Models Used:"
    echo "  $session_models"
    echo ""
    # Display cost estimate with appropriate indicator for model accuracy
    if [[ "$session_models" == *","* ]]; then
        echo "Cost Estimate (accurate, mixed models: $session_models):"
    else
        echo "Cost Estimate (based on $session_models):"
    fi
    echo "  Input tokens:    \$$input_cost"
    echo "  Output tokens:   \$$output_cost"
    echo "  Total:           \$$total_cost"
    echo ""
    log_info "Metrics log saved to: $METRICS_LOG"
    echo ""
}

# =============================================================================
# ARGUMENT PARSING & VALIDATION
# =============================================================================

# Parse optional flags
while [[ "${1:-}" == --* ]]; do
    case "$1" in
        --poorman)
            POORMAN_MODE=true
            shift
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

if [ -z "${1:-}" ] || [ -z "${2:-}" ]; then
    log_error "Usage: $0 [--poorman] <plan-dir> <iterations>"
    echo ""
    echo "Options:"
    echo "  --poorman       Skip retry logic, try sonnet once and accept any model"
    echo ""
    echo "Arguments:"
    echo "  plan-dir        Directory containing the plan (must have TODO.md)"
    echo "  iterations      Maximum number of iterations to run"
    echo ""
    echo "Examples:"
    echo "  $0 plans/arena-v2/ 10              # Run 10 iterations on arena-v2 plan"
    echo "  $0 --poorman plans/arena-v2/ 10   # Run without retry logic (cheaper)"
    exit 1
fi

PLAN_DIR="${1%/}"  # Remove trailing slash if present
ITERATIONS=$2

# Validate plan directory exists
if [ ! -d "$PLAN_DIR" ]; then
    log_error "Plan directory not found: $PLAN_DIR"
    exit 1
fi

# Validate TODO.md exists in plan directory
if [ ! -f "$PLAN_DIR/TODO.md" ]; then
    log_error "TODO.md not found in plan directory: $PLAN_DIR/TODO.md"
    exit 1
fi

# Set file paths
TODO_FILE="$PLAN_DIR/TODO.md"
PROGRESS_FILE="$PLAN_DIR/progress.txt"
METRICS_LOG="$PLAN_DIR/ralph_metrics.jsonl"

# Validate iterations is a number
if ! [[ "$ITERATIONS" =~ ^[0-9]+$ ]]; then
    log_error "Iterations must be a positive integer, got: $ITERATIONS"
    exit 1
fi

if [ "$ITERATIONS" -eq 0 ]; then
    log_error "Iterations must be greater than 0"
    exit 1
fi

log_info "Ralph Automation Script"
log_info "Plan directory: $PLAN_DIR"
log_info "Iterations: $ITERATIONS"
log_info "TODO file: $TODO_FILE"
log_info "Progress file: $PROGRESS_FILE"
log_info "Metrics file: $METRICS_LOG"
if [ "$POORMAN_MODE" = true ]; then
    log_warn "Poorman mode: retry logic disabled, using sonnet"
fi
echo ""

# =============================================================================
# PRE-FLIGHT CHECKS
# =============================================================================

# Verify required dependencies are available
if ! check_dependencies; then
    exit 1
fi

# Verify git repository state
if ! check_git_state; then
    exit 1
fi

echo ""

# =============================================================================
# FILE SETUP
# =============================================================================

# Create progress file if it doesn't exist
if [ ! -f "$PROGRESS_FILE" ]; then
    log_info "Creating progress file at $PROGRESS_FILE"
fi

# Verify we can write to both progress and metrics files
if ! touch "$PROGRESS_FILE" "$METRICS_LOG" 2>/dev/null; then
    log_error "Cannot write to progress file or metrics file"
    exit 1
fi

# =============================================================================
# MAIN LOOP
# =============================================================================

for ((i=1; i<=ITERATIONS; i++)); do
    echo "=================================================="
    echo "Iteration $i"
    echo "=================================================="
    echo ""

    # Capture start time for metrics
    ITERATION_START=$SECONDS

    # Run Claude with permission to make edits
    # Use @file syntax to reference files that Claude can read and edit
    # Use --output-format json to capture metrics
    # Separate stdout (JSON) from stderr to avoid corrupting JSON with error messages
    # Two-tier retry strategy: first try Opus, then fall back to Sonnet if needed

    # Extract current task from TODO file (first unchecked item)
    # Format: "- [ ] Task description" -> "Task description"
    CURRENT_TASK=$(grep -m 1 '^\s*- \[ \]' "$TODO_FILE" | sed 's/^\s*- \[ \] //')

    claude_json=""
    CLAUDE_EXIT_CODE=0

    if [ "$POORMAN_MODE" = true ]; then
        # Poorman mode: try sonnet once, accept any model
        start_timer
        claude_json=$(claude --output-format json --model sonnet --permission-mode acceptEdits -p "Find the highest-priority task from the TODO file and work only on that task.

Here are the current TODO items and progress:

@$TODO_FILE

@$PROGRESS_FILE

Guidelines:
1. Pick ONE task from the TODO file that you determine has the highest priority
2. Work ONLY on that task - do not work on multiple tasks
3. Update the TODO file by marking the task as complete (change [ ] to [x]) or updating its status
4. After completing the task, append your progress to the progress file (@$PROGRESS_FILE) with this format:
   - Current date/time
   - Task name
   - What was accomplished
   - Next steps (if any)

IMPORTANT: Only work on a SINGLE task per iteration.

If, while working on the task, you determine ALL tasks are complete, output exactly this:
<promise>COMPLETE</promise>" 2>/dev/null) || CLAUDE_EXIT_CODE=$?
        stop_timer
        ACTUAL_MODEL=$(echo "$claude_json" | jq -r '.modelUsage | keys[0] // "unknown"')
        echo "✓ $ACTUAL_MODEL (poorman mode)"
    else
        # Normal mode: multi-stage retry logic
        RETRY_COUNT=0
        OPUS_OBTAINED=false
        MODEL_OBTAINED=false

        echo "Trying $REQUESTED_MODEL..."

        # Stage 1: Try Opus exclusively first
    while [ $RETRY_COUNT -lt $INITIAL_OPUS_RETRIES ]; do
        start_timer
        claude_json=$(claude --output-format json --model opus --permission-mode acceptEdits -p "Find the highest-priority task from the TODO file and work only on that task.

Here are the current TODO items and progress:

@$TODO_FILE

@$PROGRESS_FILE

Guidelines:
1. Pick ONE task from the TODO file that you determine has the highest priority
2. Work ONLY on that task - do not work on multiple tasks
3. Update the TODO file by marking the task as complete (change [ ] to [x]) or updating its status
4. After completing the task, append your progress to the progress file (@$PROGRESS_FILE) with this format:
   - Current date/time
   - Task name
   - What was accomplished
   - Next steps (if any)

IMPORTANT: Only work on a SINGLE task per iteration.

If, while working on the task, you determine ALL tasks are complete, output exactly this:
<promise>COMPLETE</promise>" 2>/dev/null) || CLAUDE_EXIT_CODE=$?
        stop_timer

        # Extract actual model used
        ACTUAL_MODEL=$(echo "$claude_json" | jq -r '.modelUsage | keys[0] // "unknown"')

        # Check if requested model matches actual model
        if echo "$ACTUAL_MODEL" | grep -qi "$REQUESTED_MODEL"; then
            # Success - got Opus
            echo "✓ $REQUESTED_MODEL"
            OPUS_OBTAINED=true
            MODEL_OBTAINED=true
            break
        else
            # Opus not available, prepare to retry
            RETRY_COUNT=$((RETRY_COUNT + 1))
            if [ $RETRY_COUNT -lt $INITIAL_OPUS_RETRIES ]; then
                echo "✗ got $ACTUAL_MODEL, retrying ($RETRY_COUNT/$INITIAL_OPUS_RETRIES)..."
                sleep $RETRY_DELAY
            else
                echo "✗ opus unavailable, trying alternating strategy..."
            fi
        fi
    done

    # Stage 2: Alternate between Sonnet and Opus if Stage 1 failed
    if [ "$MODEL_OBTAINED" = false ]; then
        RETRY_COUNT=0

        while [ $RETRY_COUNT -lt $ALTERNATE_RETRIES ]; do
            # Alternate: even attempts = Sonnet, odd attempts = Opus
            if [ $((RETRY_COUNT % 2)) -eq 0 ]; then
                # Try Sonnet
                MODEL_TO_TRY="sonnet"
                TARGET_MODEL="$FALLBACK_MODEL"
            else
                # Try Opus
                MODEL_TO_TRY="opus"
                TARGET_MODEL="$REQUESTED_MODEL"
            fi

            start_timer
            claude_json=$(claude --output-format json --model "$MODEL_TO_TRY" --permission-mode acceptEdits -p "Find the highest-priority task from the TODO file and work only on that task.

Here are the current TODO items and progress:

@$TODO_FILE

@$PROGRESS_FILE

Guidelines:
1. Pick ONE task from the TODO file that you determine has the highest priority
2. Work ONLY on that task - do not work on multiple tasks
3. Update the TODO file by marking the task as complete (change [ ] to [x]) or updating its status
4. After completing the task, append your progress to the progress file (@$PROGRESS_FILE) with this format:
   - Current date/time
   - Task name
   - What was accomplished
   - Next steps (if any)

IMPORTANT: Only work on a SINGLE task per iteration.

If, while working on the task, you determine ALL tasks are complete, output exactly this:
<promise>COMPLETE</promise>" 2>/dev/null) || CLAUDE_EXIT_CODE=$?
            stop_timer

            # Extract actual model used
            ACTUAL_MODEL=$(echo "$claude_json" | jq -r '.modelUsage | keys[0] // "unknown"')

            # Check if we got the target model
            if echo "$ACTUAL_MODEL" | grep -qi "$TARGET_MODEL"; then
                if [ "$MODEL_TO_TRY" = "opus" ]; then
                    echo "✓ $REQUESTED_MODEL"
                    OPUS_OBTAINED=true
                else
                    echo "✓ $FALLBACK_MODEL (fallback)"
                fi
                MODEL_OBTAINED=true
                break
            else
                RETRY_COUNT=$((RETRY_COUNT + 1))
                if [ $RETRY_COUNT -lt $ALTERNATE_RETRIES ]; then
                    echo "✗ got $ACTUAL_MODEL, retrying ($RETRY_COUNT/$ALTERNATE_RETRIES)..."
                    sleep $RETRY_DELAY
                fi
            fi
        done

    fi

    # Stage 3: Last resort - try Haiku if both Opus and Sonnet failed
    if [ "$MODEL_OBTAINED" = false ]; then
        echo "✗ both $REQUESTED_MODEL and $FALLBACK_MODEL unavailable, trying $LAST_RESORT_MODEL..."
        RETRY_COUNT=0

        while [ $RETRY_COUNT -lt $HAIKU_RETRIES ]; do
            start_timer
            claude_json=$(claude --output-format json --model haiku --permission-mode acceptEdits -p "Find the highest-priority task from the TODO file and work only on that task.

Here are the current TODO items and progress:

@$TODO_FILE

@$PROGRESS_FILE

Guidelines:
1. Pick ONE task from the TODO file that you determine has the highest priority
2. Work ONLY on that task - do not work on multiple tasks
3. Update the TODO file by marking the task as complete (change [ ] to [x]) or updating its status
4. After completing the task, append your progress to the progress file (@$PROGRESS_FILE) with this format:
   - Current date/time
   - Task name
   - What was accomplished
   - Next steps (if any)

IMPORTANT: Only work on a SINGLE task per iteration.

If, while working on the task, you determine ALL tasks are complete, output exactly this:
<promise>COMPLETE</promise>" 2>/dev/null) || CLAUDE_EXIT_CODE=$?
            stop_timer

            # Extract actual model used
            ACTUAL_MODEL=$(echo "$claude_json" | jq -r '.modelUsage | keys[0] // "unknown"')

            # Check if we got Haiku
            if echo "$ACTUAL_MODEL" | grep -qi "$LAST_RESORT_MODEL"; then
                echo "✓ $LAST_RESORT_MODEL (last resort)"
                MODEL_OBTAINED=true
                break
            else
                RETRY_COUNT=$((RETRY_COUNT + 1))
                if [ $RETRY_COUNT -lt $HAIKU_RETRIES ]; then
                    echo "✗ got $ACTUAL_MODEL, retrying ($RETRY_COUNT/$HAIKU_RETRIES)..."
                    sleep $RETRY_DELAY
                fi
            fi
        done

        # Hard failure if even Haiku is unavailable
        if [ "$MODEL_OBTAINED" = false ]; then
            log_error "All models ($REQUESTED_MODEL, $FALLBACK_MODEL, $LAST_RESORT_MODEL) are unavailable."
            log_error "Claude API may be experiencing issues. Exiting."
            exit 1
        fi
    fi
    fi  # End of poorman mode check

    # Extract text content from JSON for completion check and display
    result=$(jq -r '.result // ""' <<< "$claude_json")

    # Extract and log metrics
    extract_iteration_metrics "$claude_json" "$ITERATION_START"

    # Auto-commit changes if files were modified
    if [ "$ITERATION_FILES_CHANGED" -gt 0 ]; then
        commit_changes "$CURRENT_TASK"
    fi

    # Display interaction result with phase separator
    echo "--- Claude Output ---"
    echo "$result"
    echo ""

    # Display metrics summary
    print_metrics_summary
    echo ""

    # Check for completion signal
    if [[ "$result" == *"<promise>COMPLETE</promise>"* ]]; then
        echo "=================================================="
        log_success "All tasks complete, exiting"
        echo "=================================================="

        # Print final summary
        print_final_summary

        # Send notification if tt is available
        if command -v tt &> /dev/null; then
            tt notify "Ralph: All tasks complete after $i iterations"
        fi

        exit 0
    fi

    echo ""
done

# If we get here, we ran out of iterations
echo "=================================================="
log_warn "Reached maximum iterations ($ITERATIONS)"
log_info "Tasks may remain incomplete - check $TODO_FILE"
echo "=================================================="
echo ""

# Print final summary
print_final_summary

log_info "Progress file: $PROGRESS_FILE"
log_info "To continue, run: $0 $PLAN_DIR $ITERATIONS"
