defmodule SymphonyElixir.GitHub.LifecycleTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.GitHub.Lifecycle
  alias SymphonyElixir.Tracker.Issue

  test "circuit-breaker cleanup marks issue blocked and appends workpad reason" do
    test_pid = self()

    request = fn method, path, params, body ->
      send(test_pid, {:github_request, method, path, params, body})

      if method == "GET" do
        {:ok,
         %{
           status: 200,
           body: [
             %{
               "id" => 88,
               "body" => "## Symphony Workpad\n\nExisting evidence.",
               "html_url" => "https://github.test/comment/88"
             }
           ]
         }}
      else
        {:ok, %{status: 200, body: %{}}}
      end
    end

    issue = %Issue{
      id: "44",
      identifier: "GH-44",
      title: "Circuit cleanup",
      native_ref: %{"repo" => "octo/repo"}
    }

    assert :ok = Lifecycle.block_issue(issue, "cached context loop", request: request)

    assert_receive {:github_request, "POST", "/repos/octo/repo/issues/44/labels", %{}, %{"labels" => ["agent-blocked"]}}

    assert_receive {:github_request, "DELETE", "/repos/octo/repo/issues/44/labels/agent-running", %{}, nil}

    assert_receive {:github_request, "PATCH", "/repos/octo/repo/issues/comments/88", %{}, %{"body" => body}}

    assert body =~ "Host circuit breaker"
    assert body =~ "cached context loop"
  end

  test "rejects invalid issue identity and missing rg before GitHub mutation" do
    invalid = %Issue{id: "not-a-number", identifier: "GH-X", native_ref: %{"repo" => "octo/repo"}}
    assert {:error, :invalid_github_issue_number} = Lifecycle.start(invalid, "/work/GH-X")

    issue = %Issue{id: "45", identifier: "GH-45", native_ref: %{"repo" => "octo/repo"}}

    command = fn _workspace, command, _env ->
      case command do
        "git branch --show-current" -> {:ok, "feature/existing\n"}
        "command -v rg" -> {:error, :not_found}
      end
    end

    assert {:error, :rg_not_found} =
             Lifecycle.start(issue, "/work/GH-45",
               command: command,
               request: fn _, _, _, _ -> flunk("GitHub must not be called") end
             )
  end

  test "owns branch, labels, workpad, verification evidence, and ready cleanup" do
    test_pid = self()

    request = fn method, path, params, body ->
      send(test_pid, {:github_request, method, path, params, body})

      cond do
        method == "GET" and String.ends_with?(path, "/comments") ->
          {:ok, %{status: 200, body: []}}

        method == "POST" and String.ends_with?(path, "/comments") ->
          {:ok,
           %{
             status: 201,
             body: %{"id" => 77, "html_url" => "https://github.test/comment/77"}
           }}

        method == "GET" and String.ends_with?(path, "/pulls") ->
          {:ok,
           %{
             status: 200,
             body: [
               %{
                 "number" => 12,
                 "state" => "open",
                 "draft" => true,
                 "html_url" => "https://github.test/pr/12"
               }
             ]
           }}

        true ->
          {:ok, %{status: 200, body: %{}}}
      end
    end

    command = fn _workspace, shell_command, _env ->
      send(test_pid, {:command, shell_command})

      case shell_command do
        "git branch --show-current" -> {:ok, "main\n"}
        "git switch -c codex/symphony-gh-42" -> {:ok, ""}
        "command -v rg" -> {:ok, "/opt/homebrew/bin/rg\n"}
      end
    end

    issue = %Issue{
      id: "42",
      identifier: "GH-42",
      title: "Lifecycle test",
      native_ref: %{"repo" => "octo/repo"},
      url: "https://github.test/octo/repo/issues/42"
    }

    assert {:ok, context} =
             Lifecycle.start(issue, "/work/GH-42", request: request, command: command)

    assert context.branch == "codex/symphony-gh-42"
    assert context.workpad_comment_id == 77
    assert context.workpad_url == "https://github.test/comment/77"
    assert context.workpad_body =~ "Lifecycle labels and verification are managed by Symphony"

    assert_receive {:command, "git branch --show-current"}
    assert_receive {:command, "git switch -c codex/symphony-gh-42"}
    assert_receive {:command, "command -v rg"}

    assert_receive {:github_request, "POST", "/repos/octo/repo/issues/42/labels", %{}, %{"labels" => ["agent-running"]}}

    assert_receive {:github_request, "DELETE", "/repos/octo/repo/issues/42/labels/agent-ready", %{}, nil}

    verification = %{
      command: "make all",
      status: :passed,
      duration_ms: 100,
      exit_code: 0,
      passed_stages: ["tests"],
      failed_stages: [],
      relevant_lines: ["10 tests, 0 failures"],
      log_path: "/work/GH-42/.symphony/verification/run.log"
    }

    assert {:ok, context} = Lifecycle.record_verification(context, verification)
    assert context.workpad_body =~ "Full log artifact"
    assert context.workpad_body =~ "10 tests, 0 failures"

    assert {:ok, %{number: 12, state: "open", draft: true}} =
             Lifecycle.find_pull_request(context)

    assert {:ok, context} = Lifecycle.finish(context, :ready, "PR #12 is ready")
    assert context.workpad_body =~ "Outcome: `READY`"

    assert_receive {:github_request, "POST", "/repos/octo/repo/issues/42/labels", %{}, %{"labels" => ["human-review"]}}

    assert_receive {:github_request, "DELETE", "/repos/octo/repo/issues/42/labels/agent-running", %{}, nil}
  end

  test "refuses phased lifecycle when rg is unavailable" do
    request = fn _method, _path, _params, _body -> {:ok, %{status: 200, body: %{}}} end

    command = fn _workspace, shell_command, _env ->
      case shell_command do
        "git branch --show-current" -> {:ok, "feature/existing\n"}
        "command -v rg" -> {:error, :not_found}
      end
    end

    issue = %Issue{
      id: "43",
      identifier: "GH-43",
      title: "Missing rg",
      native_ref: %{"repo" => "octo/repo"}
    }

    assert {:error, :rg_not_found} =
             Lifecycle.start(issue, "/work/GH-43", request: request, command: command)
  end
end
