defmodule SymphonyElixir.TaskCapsuleTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.TaskCapsule
  alias SymphonyElixir.Tracker.Issue

  test "projects issue context into a compact normalized capsule" do
    issue = %Issue{
      id: "42",
      identifier: "GH-42",
      title: "Document waiter behavior",
      url: "https://github.com/example/repo/issues/42",
      description: """
      Introductory prose that should not be replayed.

      ## Scope
      - Update `elixir/AGENTS.md`.
      - Update `elixir/README.md`.

      ## Acceptance criteria
      - The two documents agree.
      - The final gate is host-owned.

      ## Validation
      - Run `make -C elixir all`.

      ## Background
      A very long overlapping workflow narrative that should not be included.
      """
    }

    capsule =
      TaskCapsule.build(issue, "/work/GH-42",
        branch: "codex/gh-42",
        verification_command: "make -C elixir all"
      )

    assert capsule =~ "Objective: Document waiter behavior"
    assert capsule =~ "- elixir/AGENTS.md"
    assert capsule =~ "- elixir/README.md"
    assert capsule =~ "- The two documents agree."
    assert capsule =~ "Verification:\n- make -C elixir all"
    assert capsule =~ "Branch: codex/gh-42"
    assert capsule =~ "Symphony owns branch preparation"
    refute capsule =~ "very long overlapping workflow narrative"
    refute capsule =~ "Introductory prose"

    default_capsule = TaskCapsule.build(issue, "/work/GH-42")
    assert default_capsule =~ "Branch: unknown"
    assert default_capsule =~ "repository-defined focused checks"
  end

  test "phase handoffs contain only bounded diff and verification facts" do
    verification = %{
      command: "make all",
      status: :failed,
      duration_ms: 123,
      exit_code: 2,
      passed_stages: ["format"],
      failed_stages: ["tests"],
      relevant_lines: Enum.map(1..20, &"failure #{&1}"),
      log_path: "/work/.symphony/verification/run.log"
    }

    handoff =
      TaskCapsule.phase_handoff(:verification, %{
        changed_paths: ["README.md"],
        diff_status: "dirty",
        verification: verification
      })

    assert handoff =~ "Changed paths:\n- README.md"
    assert handoff =~ "Status: failed"
    assert handoff =~ "failure 20"
    assert handoff =~ "Full log artifact"

    publication =
      TaskCapsule.phase_handoff(:publication, %{
        changed_paths: ["README.md"],
        verification: verification
      })

    assert publication =~ "Load only the repository publishing skill now"
    assert publication =~ "SYMPHONY_OUTCOME: READY"
    assert publication =~ "SYMPHONY_OUTCOME: BLOCKED"
  end
end
