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

### 3. Stage and commit

Once approved:
```bash
git add -A
git commit -m "<header>" -m "<body>" -m "<footer>"
```
Omit `-m "<body>"` or `-m "<footer>"` if those sections are empty.

### 4. Push to remote

```bash
git push origin main
```

Confirm to the user once the push succeeds.
