# Copilot Instructions

## Commit Workflow

When the user asks to create a commit, follow these steps in order:

### 1. Draft the commit message

Use the template in `.gitmessage`. The rules are:

**Header** (max 50 characters)
```
<type>(<scope>): <subject>
```
- `type`: `feat` | `fix` | `docs` | `style` | `refactor` | `test` | `chore`
- `scope`: optional, specifies the area of the change (e.g. `deploy-vm`, `cloud-init`)
- `subject`: imperative present tense, no capital first letter, no trailing dot

**Body** (wrap at 72 characters)
- Explain *why* the change was made, not what
- Contrast with previous behaviour
- Imperative present tense

**Footer**
- Breaking changes: `BREAKING CHANGE: <description>`
- Closed issues: `Closes #<number>`

Present the drafted message to the user for review before doing anything else.

### 2. Wait for user approval

Do not stage files or run any git commands until the user explicitly approves the message. Approval phrases include (but are not limited to): "looks good", "ship it", "lgtm", "yes", "go ahead".

If the user requests changes to the message, revise and present again. Repeat until approved.

### 3. Commit staged changes

Once approved:
```bash
git commit -m "<header>" -m "<body>" -m "<footer>"
```
Omit `-m "<body>"` or `-m "<footer>"` if those sections are empty.

Commit only the changes the user has already staged. Do not stage additional
files unless the user explicitly asks you to do so.

### 4. Push to remote

```bash
branch="$(git branch --show-current)"
git push --set-upstream origin "$branch"
```

Push the current local branch to the remote branch with the same name. If the
remote branch does not exist, create it and configure the local branch to track
it. Never push to a different branch unless the user explicitly requests it.

Confirm to the user once the push succeeds.