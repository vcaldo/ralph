# OpenCode Support Tasks

Tasks for implementing OpenCode CLI support in ralph.sh. Each task is designed for a single ralph iteration.
Check the plan at [opencode-plan.md](opencode-plan.md)

## High Priority

- [x] **Task 1: Add configuration variables for CLI selection**
  Add new configuration variables in the CONFIGURATION section of ralph.sh:
  - Add `SELECTED_CLI="claude"` in the "Configuration (set once via CLI flags)" section after `REQUESTED_MODEL`
  - Add `OPENCODE_PROVIDER="anthropic"` after `SELECTED_CLI`
  Location: Around line 33, after `REQUESTED_MODEL="opus"`
  Do NOT modify any other code in this task.

- [x] **Task 2: Add --cli flag parsing**
  In the argument parsing section (around line 663), add handling for `--cli` flag:
  - Add a new case for `--cli)` in the while loop
  - Accept values: `claude` or `opencode`
  - Set `SELECTED_CLI` to the provided value
  - Error if invalid value provided
  - Check for `RALPH_CLI` env var before parsing (set `SELECTED_CLI="${RALPH_CLI:-claude}"` at the start)
  Pattern to follow: Copy the structure of the existing `--model)` case.
  Do NOT modify any other code in this task.

- [x] **Task 3: Add --provider flag parsing**
  In the argument parsing section (around line 663), add handling for `--provider` flag:
  - Add a new case for `--provider)` in the while loop
  - Accept values: `anthropic` or `github-copilot`
  - Set `OPENCODE_PROVIDER` to the provided value
  - Error if invalid value provided
  Pattern to follow: Copy the structure of the `--model)` case.
  Do NOT modify any other code in this task.

- [x] **Task 4: Add get_opencode_model() function**
  Add a new function after `format_duration()` (around line 227):
  ```bash
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
  ```
  Do NOT modify any other code in this task.

- [x] **Task 5: Add call_opencode_api() function**
  Add a new function after `call_claude_api()` (around line 403):
  ```bash
  # Call OpenCode API with the standard prompt
  # Sets globals: opencode_output, CLAUDE_EXIT_CODE (reusing for consistency)
  # Uses globals: REQUESTED_MODEL, TODO_FILE, PROGRESS_FILE, OPENCODE_PROVIDER
  call_opencode_api() {
      local opencode_stderr
      opencode_stderr=$(mktemp)
      CLAUDE_EXIT_CODE=0
      opencode_output=""

      # Get full model name
      local full_model
      full_model=$(get_opencode_model "$REQUESTED_MODEL")

      # Build the prompt (same as Claude)
      local prompt="Find the highest-priority task from the TODO file and work only on that task.

  Here are the current TODO items and progress files to reference.

  Guidelines:
  1. Pick ONE task from the TODO file that you determine has the highest priority
  2. Work ONLY on that task - do not work on multiple tasks
  3. Update the TODO file by marking the task as complete (change [ ] to [ ]) or updating its status
  4. After completing the task, append your progress to the progress file with this format:
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

      # Run opencode
      opencode_output=$(opencode run --format json \
          --model "$full_model" \
          --file "$TODO_FILE" \
          --file "$PROGRESS_FILE" \
          "$prompt" 2>"$opencode_stderr") || CLAUDE_EXIT_CODE=$?

      if [[ $CLAUDE_EXIT_CODE -ne 0 ]]; then
          log_stderr_file "$opencode_stderr" "error"
      else
          rm -f "$opencode_stderr"
      fi
  }
  ```
  Note: OpenCode does not support retry logic or timeout in the same way. This is a minimal implementation.
  Do NOT modify any other code in this task.

- [x] **Task 6: Add extract_iteration_metrics_opencode() function**
  Add a new function after `extract_iteration_metrics()` (around line 502):
  ```bash
  # Extract metrics from OpenCode JSONL output
  # Parameters: jsonl_output, start_time
  # Sets the same ITERATION_* globals as extract_iteration_metrics()
  extract_iteration_metrics_opencode() {
      local jsonl="$1"
      local start_time="$2"

      ITERATION_DURATION=$((SECONDS - start_time))

      # Parse JSONL and aggregate step_finish tokens
      local token_data
      token_data=$(echo "$jsonl" | jq -s '[.[] | select(.type == "step_finish") | .part.tokens // {}] | {
          input: (map(.input // 0) | add // 0),
          output: (map(.output // 0) | add // 0),
          cache_read: (map(.cache.read // 0) | add // 0),
          cache_write: (map(.cache.write // 0) | add // 0)
      }' 2>/dev/null || echo '{"input":0,"output":0,"cache_read":0,"cache_write":0}')

      ITERATION_MODEL=$(get_opencode_model "$REQUESTED_MODEL")
      ITERATION_MODELS="[\"$ITERATION_MODEL\"]"
      ITERATION_STOP_REASON="end_turn"
      ITERATION_INPUT_TOKENS=$(echo "$token_data" | jq -r '.input')
      ITERATION_OUTPUT_TOKENS=$(echo "$token_data" | jq -r '.output')
      ITERATION_CACHE_CREATE_TOKENS=$(echo "$token_data" | jq -r '.cache_write')
      ITERATION_CACHE_READ_TOKENS=$(echo "$token_data" | jq -r '.cache_read')
      ITERATION_TOTAL_TOKENS=$((ITERATION_INPUT_TOKENS + ITERATION_OUTPUT_TOKENS))

      ITERATION_FILES_CHANGED=$(git status --porcelain 2>/dev/null | wc -l)

      ITERATION_SUCCESS="true"
      if [[ $CLAUDE_EXIT_CODE -ne 0 ]]; then
          ITERATION_SUCCESS="false"
      fi

      append_metrics_log

      TOTAL_DURATION=$((TOTAL_DURATION + ITERATION_DURATION))
      TOTAL_INPUT_TOKENS=$((TOTAL_INPUT_TOKENS + ITERATION_INPUT_TOKENS))
      TOTAL_OUTPUT_TOKENS=$((TOTAL_OUTPUT_TOKENS + ITERATION_OUTPUT_TOKENS))
      TOTAL_FILES_CHANGED=$((TOTAL_FILES_CHANGED + ITERATION_FILES_CHANGED))
      INTERACTION_COUNT=$((INTERACTION_COUNT + 1))
  }
  ```
  Do NOT modify any other code in this task.

- [x] **Task 7: Add extract_result_opencode() function**
  Add a helper function to extract result text from OpenCode JSONL (add after extract_iteration_metrics_opencode):
  ```bash
  # Extract result text from OpenCode JSONL output
  # Parameters: jsonl_output
  # Returns: The concatenated text content
  extract_result_opencode() {
      local jsonl="$1"
      echo "$jsonl" | jq -rs '[.[] | select(.type == "text") | .part.text // ""] | join("")' 2>/dev/null || echo ""
  }
  ```
  Do NOT modify any other code in this task.

- [x] **Task 8: Update check_dependencies() for CLI selection**
  Modify `check_dependencies()` function (around line 174) to check for the selected CLI:
  - Replace the hardcoded claude check with a conditional based on `SELECTED_CLI`
  - If `SELECTED_CLI == "claude"`: check for `claude` binary (existing code)
  - If `SELECTED_CLI == "opencode"`: check for `opencode` binary with install message:
    ```bash
    log_error "opencode CLI not found"
    echo "  Install: go install github.com/opencode-ai/opencode@latest"
    ```
  Do NOT modify any other code in this task.

- [x] **Task 9: Update main loop to dispatch based on CLI**
  Modify the main loop (around line 814-837) to call the appropriate API and metrics functions:
  - Replace `call_claude_api` call with:
    ```bash
    if [[ "$SELECTED_CLI" == "opencode" ]]; then
        call_opencode_api
    else
        call_claude_api
    fi
    ```
  - Replace `extract_iteration_metrics "$claude_json"` with:
    ```bash
    if [[ "$SELECTED_CLI" == "opencode" ]]; then
        extract_iteration_metrics_opencode "$opencode_output" "$ITERATION_START"
        result=$(extract_result_opencode "$opencode_output")
    else
        extract_iteration_metrics "$claude_json" "$ITERATION_START"
        result=$(jq -r '.result // ""' <<< "$claude_json")
    fi
    ```
  Do NOT modify any other code in this task.

- [x] **Task 10: Update help/usage text**
  Update the usage text in the argument parsing error section (around line 689-702):
  - Add `--cli CLI` option description: "CLI to use: claude or opencode (default: claude, env: RALPH_CLI)"
  - Add `--provider PROV` option description: "OpenCode provider: anthropic or github-copilot (default: anthropic)"
  - Add examples:
    ```
    $0 --cli opencode plans/arena-v2/           # Run with OpenCode
    RALPH_CLI=opencode $0 plans/arena-v2/       # Use env var
    $0 --cli opencode --provider github-copilot plans/arena-v2/
    ```
  Do NOT modify any other code in this task.

- [x] **Task 11: Update startup info log**
  Update the log_info section that prints configuration (around line 739-749):
  - Add `log_info "CLI: $SELECTED_CLI"` after "Model:" line
  - If `SELECTED_CLI == "opencode"`, also print `log_info "Provider: $OPENCODE_PROVIDER"`
  Do NOT modify any other code in this task.

## Medium Priority

- [x] **Task 12: Run shellcheck validation**
  Run `shellcheck ralph.sh` and fix any warnings or errors introduced by the changes.
  Common issues to watch for:
  - Quote variables in comparisons
  - Use `[[ ]]` not `[ ]`
  - Use `== ` not `=` for string comparison in `[[ ]]`

## User Tests (Manual Verification)

After all tasks are complete, the user should manually test:

- [ ] **Test A**: Run `./ralph.sh plans/opencode-support/` with Claude CLI (default) - verify existing behavior works
- [ ] **Test B**: Run `./ralph.sh --cli opencode plans/opencode-support/` - verify OpenCode is called
- [ ] **Test C**: Run `RALPH_CLI=opencode ./ralph.sh plans/opencode-support/` - verify env var works
- [ ] **Test D**: Run `./ralph.sh --cli opencode --provider github-copilot plans/opencode-support/` - verify provider flag
- [ ] **Test E**: Verify metrics are recorded correctly for both CLIs in `ralph_metrics.jsonl`

---

## Notes for Ralph

Ralph will:
1. Read tasks from this file
2. Pick the highest-priority uncompleted task
3. Work ONLY on that task
4. Update this file when task is complete (mark with [ ])
5. Append progress to progress.txt
6. Continue until all tasks complete

**IMPORTANT SAFETY RULES:**
- DO NOT delete the TODO file - only edit it to mark tasks complete
- DO NOT modify code outside the specific locations mentioned in each task
- DO NOT change existing tests or add new files unless specified
- Run `shellcheck ralph.sh` after making changes to verify syntax
