defmodule SymphonyElixir.PhasedAgentRunnerTest do
  use SymphonyElixir.TestSupport, async: false

  test "runs three model phases while host owns lifecycle verification and compaction" do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-phased-runner-#{System.unique_integer([:positive])}"
      )

    source = Path.join(root, "source")
    workspaces = Path.join(root, "workspaces")
    fake_codex = Path.join(root, "fake-codex")
    on_exit(fn -> File.rm_rf(root) end)
    File.mkdir_p!(source)
    File.mkdir_p!(workspaces)

    File.write!(Path.join(source, "README.md"), "# test\n")
    git!(source, ["init", "-b", "main"])
    git!(source, ["config", "user.name", "Test User"])
    git!(source, ["config", "user.email", "test@example.com"])
    git!(source, ["add", "README.md"])
    git!(source, ["commit", "-m", "initial"])
    git!(source, ["branch", "release/docs"])

    File.write!(
      fake_codex,
      """
      #!/bin/sh
      turns=0
      while IFS= read -r line; do
        case "$line" in
          *'"method":"initialize"'*)
            printf '%s\n' '{"id":1,"result":{}}'
            ;;
          *'"method":"thread/start"'*)
            printf '%s\n' '{"id":2,"result":{"thread":{"id":"thread-phased"}}}'
            ;;
          *'"method":"thread/compact/start"'*)
            printf '%s\n' '{"id":5,"result":{}}'
            printf '%s\n' '{"method":"turn/completed"}'
            ;;
          *'"method":"turn/start"'*)
            turns=$((turns + 1))
            printf '{"id":3,"result":{"turn":{"id":"turn-%s"}}}\n' "$turns"
            if [ "$turns" -eq 1 ]; then
              printf '%s\n' 'host waiter proof' >> README.md
              git config user.name 'Test Worker'
              git config user.email 'worker@example.com'
              git add README.md
              git commit -m 'docs: prove committed handoff' >/dev/null
              text='implemented scoped change'
            elif [ "$turns" -eq 2 ]; then
              text='verification result interpreted'
            else
              case "$line" in
                *'README.md'*) ;;
                *) exit 10 ;;
              esac
              text='SYMPHONY_DELIVERY: {\\\"outcome\\\":\\\"ready\\\",\\\"commit_message\\\":\\\"docs: prove host delivery\\\",\\\"pr_title\\\":\\\"Prove host delivery\\\",\\\"summary\\\":\\\"Move deterministic delivery into Symphony.\\\"}'
            fi
            printf '{"method":"item/completed","params":{"item":{"type":"agentMessage","text":"%s"}}}\n' "$text"
            printf '%s\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """
    )

    File.chmod!(fake_codex, 0o755)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspaces,
      hook_after_create: "git clone #{source} .",
      tracker_provider: %{"delivery_base_ref" => "release/docs"},
      codex_command: "#{fake_codex} app-server",
      phased_execution: true,
      verification_command: "test ! -t 1 && test \"$COLUMNS\" = \"160\" && git diff --check",
      verification_timeout_ms: 10_000
    )

    test_pid = self()

    request = fn method, path, _params, body ->
      send(test_pid, {:github_request, method, path, body})

      cond do
        method == "GET" and String.ends_with?(path, "/comments") ->
          {:ok, %{status: 200, body: []}}

        method == "POST" and String.ends_with?(path, "/comments") ->
          {:ok,
           %{
             status: 201,
             body: %{
               "id" => 41,
               "html_url" => "https://github.com/acme/repo/issues/7#issuecomment-41",
               "body" => body["body"]
             }
           }}

        method == "GET" and String.ends_with?(path, "/pulls") ->
          {:ok,
           %{
             status: 200,
             body: [
               %{
                 "number" => 9,
                 "state" => "open",
                 "draft" => false,
                 "html_url" => "https://github.com/acme/repo/pull/9"
               }
             ]
           }}

        method == "PATCH" and String.ends_with?(path, "/pulls/9") ->
          {:ok,
           %{
             status: 200,
             body: %{
               "number" => 9,
               "state" => "open",
               "html_url" => "https://github.com/acme/repo/pull/9"
             }
           }}

        method == "PATCH" ->
          {:ok, %{status: 200, body: %{}}}

        method in ["POST", "DELETE"] ->
          {:ok, %{status: 200, body: %{}}}
      end
    end

    issue = %Issue{
      id: "7",
      identifier: "GH-7",
      title: "Document host waiter behavior",
      description: """
      ## Scope
      - Update `README.md`.

      ## Acceptance criteria
      - Explain that verification is awaited by the host.
      Open the pull request against `release/docs`.
      """,
      state: "open",
      url: "https://github.com/acme/repo/issues/7",
      labels: ["agent-ready", "documentation"],
      native_ref: %{"repo" => "acme/repo"}
    }

    assert :ok =
             AgentRunner.run(issue, self(),
               lifecycle_request: request,
               command_waiter_opts: [
                 log_path: Path.join(root, "verification.log")
               ]
             )

    updates = collect_updates([])
    assert Enum.count(updates, &match?({:phase, :implementation}, &1)) == 1
    assert Enum.count(updates, &match?({:phase, :verification}, &1)) == 2
    assert Enum.count(updates, &match?({:phase, :publication}, &1)) == 1
    assert Enum.count(updates, &match?({:compacted}, &1)) == 2
    assert Enum.count(updates, &match?({:session_started, _}, &1)) == 3
    assert Enum.count(updates, &match?({:host_wait, true}, &1)) == 1
    assert Enum.count(updates, &match?({:host_wait, false}, &1)) == 1

    assert File.read!(Path.join(root, "verification.log")) == ""

    assert Enum.any?(
             updates,
             &match?({:github, "POST", "/repos/acme/repo/issues/7/comments", _}, &1)
           )

    assert Enum.any?(updates, &match?({:github, "GET", "/repos/acme/repo/pulls", _}, &1))
    assert Enum.any?(updates, &match?({:github, "PATCH", "/repos/acme/repo/pulls/9", _}, &1))

    assert Enum.any?(updates, fn
             {:github, "POST", path, _body} -> String.ends_with?(path, "/labels")
             _ -> false
           end)
  end

  defp collect_updates(acc) do
    receive do
      {:worker_phase, "7", phase} ->
        collect_updates([{:phase, phase} | acc])

      {:worker_compacted, "7"} ->
        collect_updates([{:compacted} | acc])

      {:worker_host_wait, "7", waiting?} ->
        collect_updates([{:host_wait, waiting?} | acc])

      {:codex_worker_update, "7", %{event: :session_started, session_id: session_id}} ->
        collect_updates([{:session_started, session_id} | acc])

      {:github_request, method, path, body} ->
        collect_updates([{:github, method, path, body} | acc])

      _other ->
        collect_updates(acc)
    after
      20 -> Enum.reverse(acc)
    end
  end

  defp git!(directory, arguments) do
    {_output, 0} = System.cmd("git", arguments, cd: directory, stderr_to_stdout: true)
  end
end
