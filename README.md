# Symphony

Symphony turns project work into isolated, autonomous implementation runs, allowing teams to manage
work instead of supervising coding agents.

## Controlled Mac profile

The local profile uses GitHub Issues, one bounded container builder followed by a
fresh reviewer, and a host publication broker. New ledgers start paused; workspaces,
budgets and review handoffs persist. Authenticated controls manage execution.
Controlled threads select and verify separate named builder/reviewer permission
profiles without overriding them with legacy sandbox fields.
An approved documentation-only merge policy is available behind explicit host and
issue gates; deployments require the user. Live workers remain disabled until their
isolation, cancellation and pilot checks pass. Upstream demonstration workflows below
do not define this profile's authorization policy.

- [Architecture and code map](ARCHITECTURE.md)
- [Events Concierge profile](profiles/events-concierge/profile.py)
- [Symphony self-management project](profiles/symphony/README.md)
- [Local operator CLI and MCP client](tools/symphony_control.py)
- [Mac service and recovery guide](profiles/events-concierge/README.md)
- [Control configuration and API contract](SPEC.md#appendix-b-controlled-local-execution)

### Web operation in this fork

The local service includes a Kanban task board and optional project-specific Astra
chat with streaming replies and a project → task → work-agent hierarchy. Parent
agents supervise children and process their reports in durable conversations. A versioned
graph connects the agents, issues and PR work for future visualization. Chat uses bounded management tools to read work and preview authorized
changes; coding remains with the scheduler's workers. Browser access supports Google
sign-in with an explicit operator allowlist; existing local installations retain
operator-token login until configured. Google sign-in does not sign in the model or
change worker permissions. Authenticated browsers invoke native operator controls;
the local ledger saves task transitions immediately and mirrors routing labels to GitHub
in the background. GitHub retains issue content and publication evidence. See the
[operator guide](profiles/events-concierge/README.md#operate) for setup and limits.

Each issue has one task agent responsible for the entire task, with a searchable activity-grouped issue picker
showing creation time, priority, PR count and latest activity. Card titles open details;
click outside or press Escape to dismiss them. Card bodies select chat without opening details. The working-session selector shows the
selected `<task name> task agent` or `<work name> work agent`, with the task agent first.
Work agents and card shortcuts select retained working sessions; linked PRs remain resources.
Cards show retained session counts and their recorded working/queued phases separately from chat activity. Compact cards show three PRs, then an overflow link.
The task agent receives worker and GitHub milestone updates and coordinates individual
work agents. Confirmed PR work sessions retain their own
builder thread and checkout across design, implementation and follow-up validation.
They run sequentially within the issue budget, with a fresh reviewer for each candidate;
publication, merge and deployment keep their existing authorization gates.

[![Symphony demo video preview](.github/media/symphony-demo-poster.jpg)](https://player.vimeo.com/video/1186371009?h=5626e4b899)

_In this [demo video](https://player.vimeo.com/video/1186371009?h=5626e4b899), Symphony monitors a Linear board for work and spawns agents to handle the tasks. The agents complete the tasks and provide proof of work: CI status, PR review feedback, complexity analysis, and walkthrough videos. When accepted, the agents land the PR safely. Engineers do not need to supervise Codex; they can manage the work at a higher level._

> [!WARNING]
> Symphony is a low-key engineering preview for testing in trusted environments.

## Running Symphony

### Requirements

Symphony works best in codebases that have adopted
[harness engineering](https://openai.com/index/harness-engineering/). Symphony is the next step --
moving from managing coding agents to managing work that needs to get done.

### Option 1. Make your own

Tell your favorite coding agent to build Symphony in a programming language of your choice:

> Implement Symphony according to the following spec:
> https://github.com/openai/symphony/blob/main/SPEC.md

### Option 2. Use our experimental reference implementation

Check out [elixir/README.md](elixir/README.md) for instructions on how to set up your environment
and run the Elixir-based Symphony implementation. You can also ask your favorite coding agent to
help with the setup:

> Set up Symphony for my repository based on
> https://github.com/openai/symphony/blob/main/elixir/README.md

---

## License

This project is licensed under the [Apache License 2.0](LICENSE).
