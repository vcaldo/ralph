# Ralph Tasks - Example

Use this as a template for creating your TODO.md file.

## High Priority
- [ ] Implement first critical feature
- [ ] Fix urgent bug
- [ ] Complete critical functionality

## Medium Priority
- [ ] Add documentation
- [ ] Improve error handling
- [ ] Refactor legacy code

## Low Priority
- [ ] Polish UI
- [ ] Optimize performance
- [ ] Update README

## Completed
- [x] Setup project structure
- [x] Initial implementation

---

## Notes for Ralph

Ralph will:
1. Read tasks from this file
2. Pick the highest-priority uncompleted task
3. Work on ONLY that task
4. Update this file when task is complete (mark with [x])
5. Append progress to progress.txt
6. Continue until all tasks complete (unless iteration limit specified)

**IMPORTANT SAFETY RULES:**
- ❌ **DO NOT** deploy touch production
- ❌ **DO NOT** run production-related make targets
- ✅ **OK** to deploy to local dev environment
- ✅ **OK** to change data in dev environment
- ✅ **OK** to run other development commands (go run, npm, etc.)

Tips:
- Keep task descriptions clear and actionable
- Organize by priority (high → medium → low)
- Move completed tasks to the "Completed" section
- Add notes/comments to explain context (Ralph will see them)
