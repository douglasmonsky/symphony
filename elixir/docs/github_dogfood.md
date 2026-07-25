# GitHub dogfood lane

This is an **opt-in pilot configuration** for running Symphony against low-risk issues in a
personal fork. It is not the repository's default workflow and should not share credentials,
state, or workspaces with another Symphony deployment.

## Prerequisites

- Use a personal fork such as `<fork-owner>/<fork-repository>`, not the upstream repository.
- Create the four labels `agent-ready`, `agent-running`, `human-review`, and `agent-blocked` in
  that fork.
- Give the Symphony host a dedicated, least-privilege GitHub credential restricted to the fork.
  It needs issue read/write access for label and workpad updates, plus only the repository
  permissions required by the pilot's branch and pull-request flow.
- Supply tracker authentication to the Symphony process through `GITHUB_TOKEN` using the host's
  secret manager. Configure Git transport separately with a credential helper or SSH agent; do not
  put a token in a clone URL.
- Provision the isolated Codex home with only the Codex authentication and configuration required
  by the pilot.

Never put a credential in `WORKFLOW.md`, a repository file, a command-line flag, or launch-service
arguments. Symphony keeps configured tracker-token environment variables out of the Codex child,
while its host-side `github_api` tool retains all permissions granted to the token.

## Isolate the lane

Give one pilot process its own boundaries:

| Boundary | Pilot requirement |
| --- | --- |
| Run state | Keep the pilot `WORKFLOW.md`, logs, and operator notes under `<pilot-state-root>`. Runtime claims and blocked entries are in memory, so stopping the process clears them. |
| Workspaces | Set `workspace.root` to `<pilot-workspace-root>` and do not reuse a development checkout or another Symphony workspace root. |
| Codex home | Set `CODEX_HOME` to `<pilot-codex-home>` for the Codex child. Do not point it at an operator's normal Codex home. |
| Observability | Use a dedicated `<pilot-loopback-port>` and keep `server.host` set to `127.0.0.1`. Do not expose the pilot dashboard on a public interface. |

Start with one concurrent agent. A minimal pilot front matter is:

```yaml
---
tracker:
  kind: github
  provider:
    repo: "<fork-owner>/<fork-repository>"
    token: $GITHUB_TOKEN
  required_labels:
    - agent-ready
  active_states:
    - open
  terminal_states:
    - closed
workspace:
  root: $SYMPHONY_DOGFOOD_WORKSPACE_ROOT
agent:
  max_concurrent_agents: 1
codex:
  command: "env CODEX_HOME=$SYMPHONY_DOGFOOD_CODEX_HOME codex app-server"
  thread_sandbox: workspace-write
server:
  host: "127.0.0.1"
---
```

The process environment should resolve both path variables to dedicated pilot directories. Launch
from the built Elixir directory and keep logs with the rest of the pilot state:

```sh
./bin/symphony \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  --logs-root "<pilot-state-root>/logs" \
  --port "<pilot-loopback-port>" \
  "<pilot-state-root>/WORKFLOW.md"
```

The front matter enforces eligibility, but it does not implement the label lifecycle. The workflow
prompt must instruct the worker to follow the lifecycle below and to make idempotent GitHub
mutations through `github_api`.

## Issue contract and label lifecycle

Only an open issue carrying `agent-ready` is eligible. Add that label last, after confirming that
the issue contains:

- an objective and enough context to understand the desired outcome;
- a bounded scope and explicit out-of-scope list;
- acceptance criteria with an observable completion condition;
- exact verification commands;
- dependencies and required human decisions, all resolved; and
- no credentials, private data, or machine-specific paths.

Use exactly one issue comment whose first line is `## Symphony Workpad`. Update it in place with a
concise plan, acceptance checklist, current action, verification evidence, and blockers.

Apply labels as a small state machine:

1. **Eligible:** the operator removes stale `human-review` or `agent-blocked` labels, repairs the
   issue contract, and adds `agent-ready` last.
2. **Running:** the worker keeps `agent-ready` and adds `agent-running` before editing. This keeps
   the required-label check true while the issue is active.
3. **Successful handoff:** after publishing a verified pull request, the worker updates the
   workpad, adds `human-review`, then removes `agent-running` and `agent-ready`. The open issue is
   no longer eligible while a human reviews it.
4. **Controlled escalation:** if safe completion is impossible, the worker updates the workpad,
   adds `agent-blocked`, then removes `agent-running` and `agent-ready`. This is not a successful
   handoff and must not be relabeled `human-review`.

For another attempt, resolve the review request or blocker, update the issue contract, remove the
outcome label, and add `agent-ready` last. Do not leave `human-review` or `agent-blocked` on an
eligible issue.

## Block safely

Enter the controlled blocked state for an unresolved human decision, missing required access, or a
non-recoverable external failure. Stop making changes, record the precise blocker and evidence in
the workpad, apply `agent-blocked`, and remove both active labels. Keep the issue open.

Do not guess the missing decision, broaden token permissions, change repository settings, embed a
credential, edit an out-of-scope file, or weaken a sandbox to get past the blocker. After one failed
external mutation, inspect the failure before deciding whether a different safe action is
available; do not repeatedly retry the same mutation.

## Stop and roll back

To stop dispatch, remove `agent-ready` first. That prevents future dispatch and continuation after
the next issue refresh, but it does not interrupt an in-flight tool call. Stop the dedicated
Symphony process to halt active work, confirm the loopback listener is gone, and reconcile any
remaining `agent-running` issue into `agent-blocked` with the reason recorded in its workpad.

For rollback, close an unmerged pilot pull request or revert a merged pilot change through the
normal reviewed GitHub flow. Revoke the pilot credential, preserve the workpad and required logs
for review, and remove only the dedicated pilot state, workspace, and Codex-home directories when
they are no longer needed. Never delete shared directories or reuse a potentially modified
workspace as a clean checkout.
