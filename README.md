# Orchestrum

Orchestrum turns project work into isolated, autonomous implementation runs, allowing teams to manage
work instead of supervising coding agents. A single service can route work across configured
projects, prepare project-specific workspaces, and expose operator-facing runtime state.

[![Orchestrum demo video preview](.github/media/symphony-demo-poster.jpg)](.github/media/symphony-demo.mp4)

_In this [demo video](.github/media/symphony-demo.mp4), Orchestrum monitors a Linear board for work and spawns agents to handle the tasks. The agents complete the tasks and provide proof of work: CI status, PR review feedback, complexity analysis, and walkthrough videos. When accepted, the agents land the PR safely. Engineers do not need to supervise Codex; they can manage the work at a higher level._

> [!WARNING]
> Orchestrum is a low-key engineering preview for testing in trusted environments.

## Running Orchestrum

### Requirements

Orchestrum works best in codebases that have adopted
[harness engineering](https://openai.com/index/harness-engineering/). Orchestrum is the next step --
moving from managing coding agents to managing work that needs to get done.

### Option 1. Make your own

Tell your favorite coding agent to build Orchestrum in a programming language of your choice:

> Implement Orchestrum according to the following spec:
> https://github.com/ac-opensource/Orchestrum/blob/main/SPEC.md

### Option 2. Use our experimental reference implementation

Check out [elixir/README.md](elixir/README.md) for instructions on how to set up your environment
and run the Elixir-based Orchestrum implementation. You can also ask your favorite coding agent to
help with the setup:

> Set up Orchestrum for my repository based on
> https://github.com/ac-opensource/Orchestrum/blob/main/elixir/README.md

---

## License

This project is licensed under the [Apache License 2.0](LICENSE).
