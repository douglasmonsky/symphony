defmodule SymphonyElixir.GitHub.DeliveryTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.GitHub.Delivery
  alias SymphonyElixir.Tracker.Issue

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-delivery-#{System.unique_integer([:positive])}")
    remote = Path.join(root, "remote.git")
    seed = Path.join(root, "seed")
    workspace = Path.join(root, "workspace")
    log_path = Path.join(root, "verification.log")

    File.mkdir_p!(root)
    git!(root, ["init", "--bare", remote])
    git!(root, ["init", "-b", "main", seed])
    git!(seed, ["config", "user.name", "Test User"])
    git!(seed, ["config", "user.email", "test@example.com"])
    File.write!(Path.join(seed, "README.md"), "# Symphony\n")
    git!(seed, ["add", "README.md"])
    git!(seed, ["commit", "-m", "initial"])
    git!(seed, ["remote", "add", "origin", remote])
    git!(seed, ["push", "-u", "origin", "main"])
    git!(root, ["clone", "--branch", "main", remote, workspace])
    git!(workspace, ["config", "user.name", "Delivery Worker"])
    git!(workspace, ["config", "user.email", "worker@example.com"])
    git!(workspace, ["switch", "-c", "codex/symphony-gh-8"])
    File.write!(log_path, "passed\n")

    on_exit(fn -> File.rm_rf(root) end)

    {:ok,
     %{
       root: root,
       remote: remote,
       workspace: workspace,
       log_path: log_path,
       issue: issue(),
       verification: verification(log_path)
     }}
  end

  test "fresh delivery is idempotent and updates the existing pull on retry", context do
    File.write!(Path.join(context.workspace, "README.md"), "# Symphony\n\nHost delivery.\n")
    {:ok, pull_state} = Agent.start_link(fn -> nil end)
    request = pull_request_stub(pull_state, self())
    lifecycle = lifecycle(request)
    declaration = ready_declaration()
    diff = %{changed_paths: ["README.md"], status: "dirty"}

    assert {:ok, first} =
             Delivery.deliver(
               lifecycle,
               context.issue,
               context.workspace,
               context.verification,
               diff,
               declaration,
               delivery_opts()
             )

    assert first.number == 17
    assert first.base == "main"
    assert first.changed_paths == ["README.md"]
    assert git_output(context.workspace, ["rev-list", "--count", "origin/main..HEAD"]) == "1"

    assert git_output(context.workspace, ["rev-parse", "HEAD"]) ==
             git_output(context.workspace, ["rev-parse", "origin/codex/symphony-gh-8"])

    assert_received {:pull_request, "POST", "/repos/acme/repo/pulls", payload}
    assert payload["base"] == "main"
    assert payload["head"] == "codex/symphony-gh-8"
    assert payload["body"] =~ "#### Test Plan"
    assert payload["body"] =~ "- [x] `make all`"

    assert {:ok, second} =
             Delivery.deliver(
               lifecycle,
               context.issue,
               context.workspace,
               context.verification,
               %{diff | status: "committed"},
               declaration,
               delivery_opts()
             )

    assert second.number == first.number
    assert git_output(context.workspace, ["rev-list", "--count", "origin/main..HEAD"]) == "1"
    assert_received {:pull_request, "PATCH", "/repos/acme/repo/pulls/17", _payload}
  end

  test "delivery resumes an existing authorized local commit", context do
    File.write!(Path.join(context.workspace, "README.md"), "# Symphony\n\nCommitted work.\n")
    git!(context.workspace, ["add", "README.md"])
    git!(context.workspace, ["commit", "-m", "feat: existing work"])
    before = git_output(context.workspace, ["rev-parse", "HEAD"])
    {:ok, pull_state} = Agent.start_link(fn -> nil end)

    assert {:ok, _result} =
             Delivery.deliver(
               lifecycle(pull_request_stub(pull_state, self())),
               context.issue,
               context.workspace,
               context.verification,
               %{changed_paths: ["README.md"], status: "committed"},
               ready_declaration(),
               delivery_opts()
             )

    assert git_output(context.workspace, ["rev-parse", "HEAD"]) == before
    assert_received {:pull_request, "POST", "/repos/acme/repo/pulls", _payload}
  end

  test "delivery fails closed before GitHub writes for paths outside issue scope", context do
    File.write!(Path.join(context.workspace, "SECRET.md"), "not authorized\n")

    request = fn method, path, _params, _body ->
      flunk("unexpected GitHub request #{method} #{path}")
    end

    assert {:error, :out_of_scope_path} =
             Delivery.deliver(
               lifecycle(request),
               context.issue,
               context.workspace,
               context.verification,
               %{changed_paths: ["SECRET.md"], status: "dirty"},
               ready_declaration(),
               delivery_opts()
             )

    assert git_output(context.workspace, ["status", "--porcelain"]) == "?? SECRET.md"
  end

  test "declaration parser accepts bounded ready and blocked contracts" do
    message =
      ~s(SYMPHONY_DELIVERY: {"outcome":"ready","commit_message":"feat: deliver once","pr_title":"Deliver once","summary":"Host-owned delivery."})

    assert {:ok, %{outcome: :ready, commit_message: "feat: deliver once"}} =
             Delivery.parse_declaration(message)

    assert {:ok, %{outcome: :blocked, summary: "Needs a human choice."}} =
             Delivery.parse_declaration(~s(SYMPHONY_DELIVERY: {"outcome":"blocked","reason":"Needs a human choice."}))

    assert {:error, :missing_delivery_declaration} = Delivery.parse_declaration("READY")

    assert {:error, :invalid_delivery_outcome} =
             Delivery.parse_declaration(~s(SYMPHONY_DELIVERY: {"outcome":"later"}))

    assert {:error, :missing_commit_message} =
             Delivery.parse_declaration(~s(SYMPHONY_DELIVERY: {"outcome":"ready","pr_title":"Title","summary":"Summary"}))

    assert {:error, :missing_pr_title} =
             Delivery.parse_declaration(~s(SYMPHONY_DELIVERY: {"outcome":"ready","commit_message":"feat: valid","pr_title":" ","summary":"Summary"}))

    assert {:error, :missing_blocked_reason} =
             Delivery.parse_declaration(~s(SYMPHONY_DELIVERY: {"outcome":"blocked"}))
  end

  test "delivery rejects invalid contracts before repository mutation", context do
    options = delivery_opts()
    valid_context = lifecycle(fn _method, _path, _params, _body -> flunk("unexpected request") end)

    assert_raise KeyError, fn ->
      Delivery.deliver(
        valid_context,
        context.issue,
        context.workspace,
        context.verification,
        %{changed_paths: []},
        ready_declaration()
      )
    end

    assert {:error, :delivery_not_ready} =
             Delivery.deliver(
               valid_context,
               context.issue,
               context.workspace,
               context.verification,
               %{changed_paths: []},
               %{outcome: :blocked},
               options
             )

    assert {:error, :verification_not_passed} =
             Delivery.deliver(
               valid_context,
               context.issue,
               context.workspace,
               %{context.verification | status: :failed},
               %{changed_paths: []},
               ready_declaration(),
               options
             )

    assert {:error, :invalid_delivery_context} =
             Delivery.deliver(
               %{valid_context | request: :not_a_function},
               context.issue,
               context.workspace,
               context.verification,
               %{changed_paths: []},
               ready_declaration(),
               options
             )

    assert {:error, :no_changed_paths} =
             Delivery.deliver(
               valid_context,
               context.issue,
               context.workspace,
               context.verification,
               %{changed_paths: []},
               ready_declaration(),
               options
             )
  end

  test "delivery rejects stale diff summaries and repository command failures", context do
    File.write!(Path.join(context.workspace, "README.md"), "# changed\n")
    request = fn _method, _path, _params, _body -> flunk("unexpected request") end

    assert {:error, :changed_paths_mismatch} =
             Delivery.deliver(
               lifecycle(request),
               context.issue,
               context.workspace,
               context.verification,
               %{changed_paths: ["OTHER.md"]},
               ready_declaration(),
               delivery_opts()
             )

    status_failure = fn
      _workspace, ["status", "--porcelain"], [] -> {:error, :status_failed}
      workspace, arguments, env -> run_git(workspace, arguments, env)
    end

    assert {:error, :status_failed} =
             Delivery.deliver(
               lifecycle(request),
               context.issue,
               context.workspace,
               context.verification,
               %{changed_paths: ["README.md"]},
               ready_declaration(),
               Keyword.put(delivery_opts(), :command, status_failure)
             )

    assert {:error, %{status: _status}} =
             Delivery.deliver(
               lifecycle(request),
               context.issue,
               context.workspace,
               context.verification,
               %{changed_paths: ["README.md"]},
               ready_declaration(),
               Keyword.put(delivery_opts(), :expected_base, "missing")
             )
  end

  test "delivery bounds push and pull-request failures", context do
    File.write!(Path.join(context.workspace, "README.md"), "# committed\n")
    git!(context.workspace, ["add", "README.md"])
    git!(context.workspace, ["commit", "-m", "feat: committed"])
    git!(context.workspace, ["remote", "set-url", "origin", Path.join(context.root, "missing.git")])

    assert {:error, {:push_failed, %{status: _status}}} =
             Delivery.deliver(
               lifecycle(fn _method, _path, _params, _body -> flunk("unexpected request") end),
               context.issue,
               context.workspace,
               context.verification,
               %{changed_paths: ["README.md"]},
               ready_declaration(),
               delivery_opts()
             )

    git!(context.workspace, ["remote", "set-url", "origin", context.remote])

    assert {:error, {:pull_lookup_failed, {:error, :offline}}} =
             Delivery.deliver(
               lifecycle(fn "GET", _path, _params, nil -> {:error, :offline} end),
               context.issue,
               context.workspace,
               context.verification,
               %{changed_paths: ["README.md"]},
               ready_declaration(),
               delivery_opts()
             )

    invalid_pull = fn "GET", _path, _params, nil ->
      {:ok, %{status: 200, body: [%{}]}}
    end

    assert {:error, :invalid_pull_response} =
             Delivery.deliver(
               lifecycle(invalid_pull),
               context.issue,
               context.workspace,
               context.verification,
               %{changed_paths: ["README.md"]},
               ready_declaration(),
               delivery_opts()
             )

    failed_create = fn
      "GET", _path, _params, nil -> {:ok, %{status: 200, body: []}}
      "POST", _path, _params, _body -> {:error, :denied}
    end

    assert {:error, {:pull_write_failed, {:error, :denied}}} =
             Delivery.deliver(
               lifecycle(failed_create),
               context.issue,
               context.workspace,
               context.verification,
               %{changed_paths: ["README.md"]},
               ready_declaration(),
               delivery_opts()
             )
  end

  defp issue do
    %Issue{
      id: "8",
      identifier: "GH-8",
      title: "Move publication into the host",
      description: "## Scope\n- Update `README.md`.",
      native_ref: %{"repo" => "acme/repo"}
    }
  end

  defp lifecycle(request) do
    %{
      enabled: true,
      repo: "acme/repo",
      branch: "codex/symphony-gh-8",
      request: request
    }
  end

  defp verification(log_path) do
    %{
      command: "make all",
      status: :passed,
      exit_code: 0,
      log_path: log_path
    }
  end

  defp ready_declaration do
    %{
      outcome: :ready,
      commit_message: "feat: deliver once",
      pr_title: "Deliver once",
      summary: "Move deterministic delivery into the host."
    }
  end

  defp delivery_opts do
    [expected_base: "main", authorized_paths: ["README.md"]]
  end

  defp pull_request_stub(state, recipient) do
    fn
      "GET", "/repos/acme/repo/pulls", _params, nil ->
        pulls =
          case Agent.get(state, & &1) do
            nil -> []
            pull -> [pull]
          end

        {:ok, %{status: 200, body: pulls}}

      "POST", "/repos/acme/repo/pulls", _params, body ->
        send(recipient, {:pull_request, "POST", "/repos/acme/repo/pulls", body})
        pull = pull()
        Agent.update(state, fn _ -> pull end)
        {:ok, %{status: 201, body: pull}}

      "PATCH", "/repos/acme/repo/pulls/17", _params, body ->
        send(recipient, {:pull_request, "PATCH", "/repos/acme/repo/pulls/17", body})
        {:ok, %{status: 200, body: pull()}}
    end
  end

  defp pull do
    %{
      "number" => 17,
      "state" => "open",
      "html_url" => "https://github.test/acme/repo/pull/17"
    }
  end

  defp git!(directory, arguments) do
    case System.cmd("git", arguments, cd: directory, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> flunk("git #{Enum.join(arguments, " ")} failed #{status}: #{output}")
    end
  end

  defp git_output(directory, arguments) do
    {output, 0} = System.cmd("git", arguments, cd: directory, stderr_to_stdout: true)
    String.trim(output)
  end

  defp run_git(workspace, arguments, env) do
    case System.cmd("git", arguments, cd: workspace, env: env, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, %{status: status, output: output}}
    end
  end
end
