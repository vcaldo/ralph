#!/bin/bash
# Ralph - Automated iterative development using Claude
# Reads tasks from a TODO file, executes work, tracks progress, and commits changes

set -euo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

# --- Constants (immutable) ---
# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m' # No Color

# Spinner characters for progress display
readonly SPINNER_CHARS='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'

# Retry configuration
readonly MAX_RETRIES=3
readonly INITIAL_BACKOFF_SECONDS=5
readonly CLAUDE_TIMEOUT_SECONDS=600  # 10 minute timeout per attempt

# Visual formatting
readonly SEPARATOR="=================================================="

# --- Configuration (set once via CLI flags or defaults) ---
# Model configuration
REQUESTED_MODEL="opus"     # Configurable via --model flag, defaults to opus
# Allow overriding selected CLI via environment variable RALPH_CLI
SELECTED_CLI="${RALPH_CLI:-claude}"     # CLI to use: claude or opencode
OPENCODE_PROVIDER="anthropic"  # OpenCode provider when using opencode

# --- Global state (modified during execution) ---
# Metrics tracking variables (METRICS_LOG set after PLAN_DIR is validated)
METRICS_LOG=""
TOTAL_DURATION=0
TOTAL_INPUT_TOKENS=0
TOTAL_OUTPUT_TOKENS=0
TOTAL_FILES_CHANGED=0
INTERACTION_COUNT=0

# Timer/chronograph state
TIMER_PID=""
TIMER_START_TIME=0

# Signal handling state
INTERRUPTED=false

# --- Per-iteration state (reset each loop) ---
# These are set fresh for each iteration
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

print_separator() {
    echo "$SEPARATOR"
}

# Log contents of a stderr file if non-empty, then clean up
# Arguments: $1 = file path, $2 = log level ("warn" or "error")
log_stderr_file() {
    local file="$1"
    local level="${2:-error}"
    if [[ -s "$file" ]]; then
        if [[ "$level" == "warn" ]]; then
            log_warn "Error output:"
        else
            log_error "Error output:"
        fi
        cat "$file" >&2
    fi
    rm -f "$file"
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
        # Check if process exists before waiting (prevents race condition)
        if kill -0 "$TIMER_PID" 2>/dev/null; then
            kill "$TIMER_PID" 2>/dev/null || true
            wait "$TIMER_PID" 2>/dev/null || true
        fi
        TIMER_PID=""
    fi

    # Clear the timer line using ANSI escape sequence
    printf "\r\033[K"
}

# =============================================================================
# DEPENDENCY CHECKS
# =============================================================================

# Check if a standard command is available, with cross-platform install instructions
# Arguments: $1 = command name
# Returns: 0 if found, 1 if missing (also prints install instructions)
require_command() {
    local cmd="$1"
    if command -v "$cmd" &> /dev/null; then
        return 0
    fi
    log_error "$cmd not found"
    echo "  Install (Ubuntu/Debian): sudo apt install $cmd"
    echo "  Install (macOS): brew install $cmd"
    echo "  Install (Fedora): sudo dnf install $cmd"
    return 1
}

# Check that all required dependencies are available
# Returns 0 if all dependencies are present, 1 otherwise
check_dependencies() {
    local missing_deps=0

    # Check for claude CLI (special install instructions)
    if ! command -v claude &> /dev/null; then
        log_error "claude CLI not found"
        echo "  Install: npm install -g @anthropic-ai/claude-code"
        echo "  Or visit: https://docs.anthropic.com/claude-code"
        missing_deps=1
    fi

    # Check for jq and git
    require_command jq || missing_deps=1
    require_command git || missing_deps=1

    # If git is available, check for identity configuration
    if command -v git &> /dev/null; then
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

# Translate ralph model name to OpenCode format
# Parameters: model (opus|sonnet|haiku)
# Uses: OPENCODE_PROVIDER
# Returns: Full model name (e.g., "anthropic/claude-opus-4-5")
get_opencode_model() {
    local model="$1"
    local suffix
    case "$model" in
        opus) suffix="claude-opus-4-5" ;;
        sonnet) suffix="claude-sonnet-4-5" ;;
        haiku) suffix="claude-haiku-4-5" ;;
        *) suffix="claude-opus-4-5" ;;
    esac

    # Adjust format based on provider
    if [[ "$OPENCODE_PROVIDER" == "github-copilot" ]]; then
        # github-copilot uses dots instead of dashes
        suffix="${suffix//-4-5/.4.5}"
    fi

    echo "${OPENCODE_PROVIDER}/${suffix}"
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

# Extract commit message from Claude's response
# Returns the commit message or empty string if not found
extract_commit_message() {
    local result="$1"
    # Extract content between <commit> and </commit> tags
    # Use grep -oP for Perl regex with lookbehind/lookahead
    # Use || true to prevent set -e from exiting when grep finds no match
    echo "$result" | grep -oP '(?<=<commit>).*(?=</commit>)' | tail -1 || true
}

# Call Claude API with the standard prompt
# Includes retry logic with exponential backoff and timeout
# Sets globals: claude_json, CLAUDE_EXIT_CODE
# Uses globals: REQUESTED_MODEL, TODO_FILE, PROGRESS_FILE, MAX_RETRIES, INITIAL_BACKOFF_SECONDS, CLAUDE_TIMEOUT_SECONDS
call_claude_api() {
    local attempt=1
    local backoff=$INITIAL_BACKOFF_SECONDS
    local claude_stderr

    while [[ $attempt -le $MAX_RETRIES ]]; do
        # Check if interrupted before attempting
        if [[ "$INTERRUPTED" == true ]]; then
            return 1
        fi

        claude_stderr=$(mktemp)
        CLAUDE_EXIT_CODE=0
        claude_json=""

        # Build the prompt (extracted to avoid duplication between timeout/no-timeout paths)
        local prompt="Find the highest-priority task from the TODO file and work only on that task.

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
5. At the END of your response, output a commit message for your changes:
   <commit>Brief description of changes (imperative mood, under 72 chars)</commit>

IMPORTANT: Only work on a SINGLE task per iteration.
IMPORTANT: NEVER delete the TODO file - only edit it to mark tasks complete.

If, while working on the task, you determine ALL tasks are complete, output exactly this:
<promise>COMPLETE</promise>"

        # Run claude with timeout (if available)
        if command -v timeout &> /dev/null; then
            claude_json=$(timeout "$CLAUDE_TIMEOUT_SECONDS" claude --output-format json --model "$REQUESTED_MODEL" --permission-mode bypassPermissions -p "$prompt" 2>"$claude_stderr") || CLAUDE_EXIT_CODE=$?
        else
            # Fallback: run without timeout if 'timeout' command unavailable
            claude_json=$(claude --output-format json --model "$REQUESTED_MODEL" --permission-mode bypassPermissions -p "$prompt" 2>"$claude_stderr") || CLAUDE_EXIT_CODE=$?
        fi

        # Success - clean up and return
        if [[ $CLAUDE_EXIT_CODE -eq 0 ]]; then
            rm -f "$claude_stderr"
            return 0
        fi

        # Determine error type for logging
        local error_type="error"
        if [[ $CLAUDE_EXIT_CODE -eq 124 ]]; then
            error_type="timeout after ${CLAUDE_TIMEOUT_SECONDS}s"
        fi

        # Stop timer before logging so messages aren't overwritten
        stop_timer

        # Log the failure
        if [[ $attempt -lt $MAX_RETRIES ]]; then
            log_warn "Attempt $attempt/$MAX_RETRIES failed ($error_type), retrying in ${backoff}s..."
            log_stderr_file "$claude_stderr" "warn"
            sleep $backoff
            # Check if interrupted during sleep
            if [[ "$INTERRUPTED" == true ]]; then
                return 1
            fi
            backoff=$((backoff * 2))  # Exponential backoff
            # Restart timer for next attempt
            start_timer
        else
            # Final attempt failed
            log_error "All $MAX_RETRIES attempts failed"
            log_error "Claude CLI failed with exit code $CLAUDE_EXIT_CODE ($error_type)"
            log_stderr_file "$claude_stderr" "error"
        fi

        attempt=$((attempt + 1))
    done
}

# =============================================================================
# SIGNAL HANDLING (Graceful Interrupt)
# =============================================================================

# Print continuation instructions (used at script end and on interrupt)
print_continuation_info() {
    log_info "Progress file: $PROGRESS_FILE"
    if [[ "$INFINITE_MODE" == true ]]; then
        log_info "To continue, run: $0 $PLAN_DIR"
    else
        log_info "To continue, run: $0 $PLAN_DIR $ITERATIONS"
    fi
}

on_interrupt() {
    # Set flag to signal graceful shutdown
    INTERRUPTED=true

    # Stop timer if running to clean up display
    stop_timer

    echo ""
    print_separator
    log_warn "Script interrupted (received signal)"
    print_separator
}

# Graceful exit function - called when INTERRUPTED flag is set
graceful_exit() {
    # Print final summary with metrics collected so far
    print_final_summary
    print_continuation_info

    # Exit with standard signal code
    exit 130
}

# Set up signal trap for graceful interruption
trap 'on_interrupt' SIGINT SIGTERM

# =============================================================================
# METRICS FUNCTIONS
# =============================================================================

extract_iteration_metrics() {
    local json="$1"
    local start_time="$2"

    # Calculate duration
    ITERATION_DURATION=$((SECONDS - start_time))

    # Validate JSON output - fail fast on invalid JSON
    if ! echo "$json" | jq empty 2>/dev/null; then
        log_error "Invalid JSON response from Claude API"
        log_error "Response (first 200 chars): ${json:0:200}..."
        exit 1
    fi

    # Extract metrics from JSON with defaults (single jq pass for efficiency)
    local metrics_json
    metrics_json=$(echo "$json" | jq -r '{
        model: (.modelUsage | to_entries | max_by(.value.inputTokens + .value.outputTokens) | .key // "unknown"),
        models: (.modelUsage | keys // ["unknown"]),
        stop_reason: (.type // "unknown"),
        input_tokens: (.usage.input_tokens // 0),
        output_tokens: (.usage.output_tokens // 0),
        cache_create_tokens: (.usage.cache_creation_input_tokens // 0),
        cache_read_tokens: (.usage.cache_read_input_tokens // 0)
    }' 2>/dev/null || echo '{"model":"unknown","models":["unknown"],"stop_reason":"unknown","input_tokens":0,"output_tokens":0,"cache_create_tokens":0,"cache_read_tokens":0}')

    ITERATION_MODEL=$(echo "$metrics_json" | jq -r '.model')
    ITERATION_MODELS=$(echo "$metrics_json" | jq -c '.models')
    ITERATION_STOP_REASON=$(echo "$metrics_json" | jq -r '.stop_reason')
    ITERATION_INPUT_TOKENS=$(echo "$metrics_json" | jq -r '.input_tokens')
    ITERATION_OUTPUT_TOKENS=$(echo "$metrics_json" | jq -r '.output_tokens')
    ITERATION_CACHE_CREATE_TOKENS=$(echo "$metrics_json" | jq -r '.cache_create_tokens')
    ITERATION_CACHE_READ_TOKENS=$(echo "$metrics_json" | jq -r '.cache_read_tokens')
    ITERATION_TOTAL_TOKENS=$((ITERATION_INPUT_TOKENS + ITERATION_OUTPUT_TOKENS))

    # Calculate files changed (count all modified and untracked files in git)
    ITERATION_FILES_CHANGED=$(git status --porcelain 2>/dev/null | wc -l)

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
        --argjson models "$ITERATION_MODELS" \
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
            models: $models,
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

    # Format models list for display
    local models_display
    models_display=$(echo "$ITERATION_MODELS" | jq -r 'join(", ")')

    # Print simple list format (no box borders)
    echo "--- Iteration Metrics ---"
    echo "Duration: $duration_str"
    echo "Models: $models_display"
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
    print_separator
    echo "                  FINAL SUMMARY"
    print_separator
    echo ""

    # Calculate all aggregate metrics in a single jq pass for efficiency
    local aggregates
    aggregates=$(jq -s '{
        success_count: ([.[] | select(.success == true)] | length),
        min_duration: (map(.duration_seconds) | min // 0),
        max_duration: (map(.duration_seconds) | max // 0),
        total_cache_create: (map(.usage.cache_creation_tokens) | add // 0),
        total_cache_read: (map(.usage.cache_read_tokens) | add // 0)
    }' "$METRICS_LOG" 2>/dev/null || echo '{"success_count":0,"min_duration":0,"max_duration":0,"total_cache_create":0,"total_cache_read":0}')

    local success_count=$(echo "$aggregates" | jq -r '.success_count')
    local min_duration=$(echo "$aggregates" | jq -r '.min_duration')
    local max_duration=$(echo "$aggregates" | jq -r '.max_duration')
    local total_cache_create=$(echo "$aggregates" | jq -r '.total_cache_create')
    local total_cache_read=$(echo "$aggregates" | jq -r '.total_cache_read')

    # Calculate success rate
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

    # Calculate average tokens
    local avg_tokens=0
    if [[ $INTERACTION_COUNT -gt 0 ]]; then
        avg_tokens=$(( (TOTAL_INPUT_TOKENS + TOTAL_OUTPUT_TOKENS) / INTERACTION_COUNT ))
    fi

    # Calculate overall cache hit rate
    local cache_hit_rate=$(calculate_cache_hit_rate "$total_cache_read" "$TOTAL_INPUT_TOKENS")

    # Format total duration
    local total_duration_str=$(format_duration "$TOTAL_DURATION")

    echo "Iterations:"
    if [[ "$INFINITE_MODE" == true ]]; then
        echo "  Completed:       $INTERACTION_COUNT (unlimited mode)"
    else
        echo "  Completed:       $INTERACTION_COUNT / $ITERATIONS"
    fi
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
    log_info "Metrics log saved to: $METRICS_LOG"
    echo ""
}

# =============================================================================
# ARGUMENT PARSING & VALIDATION
# =============================================================================

# Parse optional flags
while [[ "${1:-}" == --* ]]; do
    case "$1" in
        --model)
            if [[ -z "${2:-}" ]] || [[ "${2:-}" == --* ]]; then
                log_error "--model requires an argument (haiku|sonnet|opus)"
                exit 1
            fi
            case "$2" in
                haiku|sonnet|opus)
                    REQUESTED_MODEL="$2"
                    shift 2
                    ;;
                *)
                    log_error "Invalid model: $2 (must be haiku, sonnet, or opus)"
                    exit 1
                    ;;
            esac
            ;;

        --provider)
            if [[ -z "${2:-}" ]] || [[ "${2:-}" == --* ]]; then
                log_error "--provider requires an argument (anthropic|github-copilot)"
                exit 1
            fi
            case "$2" in
                anthropic|github-copilot)
                    OPENCODE_PROVIDER="$2"
                    shift 2
                    ;;
                *)
                    log_error "Invalid provider: $2 (must be anthropic or github-copilot)"
                    exit 1
                    ;;
            esac
            ;;

        --cli)
            if [[ -z "${2:-}" ]] || [[ "${2:-}" == --* ]]; then
                log_error "--cli requires an argument (claude|opencode)"
                exit 1
            fi
            case "$2" in
                claude|opencode)
                    SELECTED_CLI="$2"
                    shift 2
                    ;;
                *)
                    log_error "Invalid CLI: $2 (must be claude or opencode)"
                    exit 1
                    ;;
            esac
            ;;

        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

if [[ -z "${1:-}" ]]; then
    log_error "Usage: $0 [options] <plan-dir> [iterations]"
    echo ""
    echo "Options:"
    echo "  --model MODEL          Specify which model to use (haiku, sonnet, or opus). Default: opus"
    echo "  --cli CLI              CLI to use: claude or opencode (default: claude, env: RALPH_CLI)"
    echo "  --provider PROV        OpenCode provider: anthropic or github-copilot (default: anthropic)"
    echo ""
    echo "Arguments:"
    echo "  plan-dir               Directory containing the plan (must have TODO.md)"
    echo "  iterations             (optional) Maximum number of iterations to run. If omitted, runs until completion."
    echo ""
    echo "Examples:"
    echo "  $0 plans/arena-v2/                 # Run until complete (unlimited)"
    echo "  $0 plans/arena-v2/ 10              # Run max 10 iterations using opus"
    echo "  $0 --model sonnet plans/arena-v2/  # Run until complete using sonnet"
    exit 1
fi

PLAN_DIR="${1%/}"  # Remove trailing slash if present
ITERATIONS=${2:-}
INFINITE_MODE=false

# Validate plan directory exists
if [[ ! -d "$PLAN_DIR" ]]; then
    log_error "Plan directory not found: $PLAN_DIR"
    exit 1
fi

# Validate TODO.md exists in plan directory
if [[ ! -f "$PLAN_DIR/TODO.md" ]]; then
    log_error "TODO.md not found in plan directory: $PLAN_DIR/TODO.md"
    exit 1
fi

# Set file paths
TODO_FILE="$PLAN_DIR/TODO.md"
PROGRESS_FILE="$PLAN_DIR/progress.txt"
METRICS_LOG="$PLAN_DIR/ralph_metrics.jsonl"

# Validate and configure iteration mode
if [[ -z "$ITERATIONS" ]]; then
    # No iterations specified - run in infinite mode
    INFINITE_MODE=true
    ITERATIONS=0  # Set to 0 for consistency in conditionals
else
    # Iterations specified - validate it's a positive integer
    if ! [[ "$ITERATIONS" =~ ^[0-9]+$ ]] || [[ "$ITERATIONS" -eq 0 ]]; then
        log_error "Iterations must be a positive integer (or omit for unlimited), got: $ITERATIONS"
        exit 1
    fi
fi

log_info "Ralph Automation Script"
log_info "Plan directory: $PLAN_DIR"
if [[ "$INFINITE_MODE" == true ]]; then
    log_info "Iterations: unlimited (until completion)"
else
    log_info "Iterations: $ITERATIONS"
fi
log_info "Model: $REQUESTED_MODEL"
log_info "TODO file: $TODO_FILE"
log_info "Progress file: $PROGRESS_FILE"
log_info "Metrics file: $METRICS_LOG"
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

# Verify we can write to progress file
if ! touch "$PROGRESS_FILE" 2>/dev/null; then
    log_error "Cannot write to progress file: $PROGRESS_FILE"
    exit 1
fi

# Verify we can write to metrics file
if ! touch "$METRICS_LOG" 2>/dev/null; then
    log_error "Cannot write to metrics file: $METRICS_LOG"
    exit 1
fi

# =============================================================================
# MAIN LOOP
# =============================================================================

CURRENT_ITERATION=0
while true; do
    CURRENT_ITERATION=$((CURRENT_ITERATION + 1))

    # Break if exceeded max iterations (finite mode only)
    if [[ "$INFINITE_MODE" == false ]] && [[ $CURRENT_ITERATION -gt $ITERATIONS ]]; then
        break
    fi

    print_separator
    if [[ "$INFINITE_MODE" == true ]]; then
        echo "Iteration $CURRENT_ITERATION (unlimited)"
    else
        echo "Iteration $CURRENT_ITERATION / $ITERATIONS"
    fi
    print_separator
    echo ""

    # Capture start time for metrics
    ITERATION_START=$SECONDS

    # Run Claude with permission to make edits
    # Use @file syntax to reference files that Claude can read and edit
    # Use --output-format json to capture metrics
    # Separate stdout (JSON) from stderr to avoid corrupting JSON with error messages

    claude_json=""
    CLAUDE_EXIT_CODE=0

    echo "Running $REQUESTED_MODEL..."
    start_timer
    call_claude_api
    stop_timer

    # Check if interrupted - exit gracefully
    if [[ "$INTERRUPTED" == true ]]; then
        graceful_exit
    fi

    # Check for API errors
    if [[ $CLAUDE_EXIT_CODE -ne 0 ]]; then
        log_error "API call failed with exit code $CLAUDE_EXIT_CODE"
        exit 1
    fi

    # Extract text content from JSON for completion check and display
    result=$(jq -r '.result // ""' <<< "$claude_json")

    # Extract and log metrics
    extract_iteration_metrics "$claude_json" "$ITERATION_START"

    # Extract commit message from Claude's response
    COMMIT_MSG=$(extract_commit_message "$result")
    if [[ -z "$COMMIT_MSG" ]]; then
        COMMIT_MSG="Ralph: iteration $CURRENT_ITERATION"
    fi

    # Auto-commit changes if files were modified
    if [[ "$ITERATION_FILES_CHANGED" -gt 0 ]]; then
        commit_changes "$COMMIT_MSG"
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
        print_separator
        log_success "All tasks complete, exiting"
        print_separator

        # Print final summary
        print_final_summary

        # Send notification if tt is available
        if command -v tt &> /dev/null; then
            tt notify "Ralph: All tasks complete after $CURRENT_ITERATION iterations"
        fi

        exit 0
    fi

    echo ""
done

# If we get here, we ran out of iterations
print_separator
log_warn "Reached maximum iterations ($ITERATIONS)"
log_info "Tasks may remain incomplete - check $TODO_FILE"
print_separator
echo ""

# Print final summary
print_final_summary

print_continuation_info
