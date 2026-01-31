## Goal
Break down the plan at `{plan_file}` into actionable tasks, updating `TODO.md` in the same directory.

## Context
This will be executed by Ralph, an LLM with less context than you. Each task is a single iteration - Ralph completes one task, commits, then exits.

At the top of TODO.md, include a reference to the source plan:
```
> 📋 **Source Plan:** `{plan_file}` — Refer to this for additional context if needed.
```

## Output Requirements
- Use `[ ]` checkbox format for every task
- Organize by priority: high → medium → low
- Order tasks so dependencies come first

## Task Granularity
- Each task should be completable in ~5-10 minutes
- One task = one logical change (single file or tightly coupled files)
- If a task touches 3+ unrelated files, split it into separate tasks

## Each Task Must Include
- Clear action verb (Add, Create, Update, Fix, Remove)
- Target file path(s)
- Expected outcome or acceptance criteria
- Relevant context Ralph needs to execute without research

## Code Snippets
- Include: function signatures, import statements, key logic patterns, exact file paths
- Omit: full implementations Ralph can infer, boilerplate code
- When helpful: reference line numbers or existing patterns to follow

## Task Dependencies
- If task B requires task A, note: "Depends on: [task A reference]"
- Group related tasks together under a subheading when logical

## When Unclear
- If the plan is ambiguous, state assumptions made
- Flag tasks needing human review with ⚠️

## Example Task Format
```
### Feature: User Authentication

- [ ] **Create auth middleware** (`src/middleware/auth.ts`)
  - Export `validateToken(req, res, next)` function
  - Use existing `jwt.verify()` pattern from `src/utils/jwt.ts`
  - Return 401 if token invalid

- [ ] **Add auth routes** (`src/routes/auth.ts`) — Depends on: auth middleware
  - POST `/login` - validate credentials, return JWT
  - POST `/logout` - invalidate token
  - Follow route pattern in `src/routes/users.ts`
```
