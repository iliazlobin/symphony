# Symphony

Symphony turns project work into isolated, autonomous implementation runs, allowing teams to manage
work instead of supervising coding agents.

## Controlled Mac profile

The local profile uses GitHub Issues, one bounded container builder followed by a
fresh reviewer, and a host publication broker. New ledgers start paused; workspaces,
budgets and review handoffs persist. Authenticated local controls manage execution.
Controlled threads select and verify separate named builder/reviewer permission
profiles without overriding them with legacy sandbox fields.
An approved documentation-only merge policy is available behind explicit host and
issue gates; deployments require the user. Live workers remain disabled until their
isolation, cancellation and pilot checks pass. Upstream demonstration workflows below
do not define this profile's authorization policy.

- [Architecture and code map](ARCHITECTURE.md)
- [Events Concierge profile](profiles/events-concierge/profile.py)
- [Local operator CLI and MCP client](tools/symphony_control.py)
- [Mac service and recovery guide](profiles/events-concierge/README.md)
- [Control configuration and API contract](SPEC.md#appendix-b-controlled-local-execution)

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
