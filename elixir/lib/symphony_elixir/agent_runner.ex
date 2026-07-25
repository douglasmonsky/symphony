defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single tracker work item in its workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.CommandWaiter
  alias SymphonyElixir.Config
  alias SymphonyElixir.GitHub.Delivery
  alias SymphonyElixir.GitHub.Lifecycle
  alias SymphonyElixir.PromptBuilder
  alias SymphonyElixir.TaskCapsule
  alias SymphonyElixir.Tracker
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.Workspace

  @type worker_host :: String.t() | nil

  @doc false
  @spec continue_with_issue_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:continue, Issue.t()} | {:done, Issue.t()} | {:error, term()}
  def continue_with_issue_for_test(%Issue{} = issue, issue_state_fetcher)
      when is_function(issue_state_fetcher, 1) do
    continue_with_issue?(issue, issue_state_fetcher)
  end

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host = selected_worker_host(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace)

        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host) do
            if phased_execution?(issue, worker_host) do
              run_phased_execution(workspace, issue, codex_update_recipient, opts)
            else
              run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host)
            end
          end
        after
          Workspace.run_after_run_hook(workspace, issue, worker_host)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp codex_message_handler(recipient, issue) do
    fn message ->
      send_codex_update(recipient, issue, message)
    end
  end

  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

  defp phased_codex_message_handler(recipient, issue, phase, collector) do
    fn message ->
      collect_agent_message(collector, message)
      send_codex_update(recipient, issue, Map.put(message, :phase, phase))
    end
  end

  defp send_worker_phase(recipient, %Issue{id: issue_id}, phase)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:worker_phase, issue_id, phase})
    :ok
  end

  defp send_worker_phase(_recipient, _issue, _phase), do: :ok

  defp send_host_wait(recipient, %Issue{id: issue_id}, waiting?)
       when is_binary(issue_id) and is_pid(recipient) and is_boolean(waiting?) do
    send(recipient, {:worker_host_wait, issue_id, waiting?})
    :ok
  end

  defp send_host_wait(_recipient, _issue, _waiting?), do: :ok

  defp mark_lifecycle_finishing(recipient, %Issue{id: issue_id}, outcome)
       when is_binary(issue_id) and is_pid(recipient) and outcome in [:ready, :blocked] do
    if recipient == self() do
      :ok
    else
      try do
        GenServer.call(recipient, {:worker_lifecycle_finishing, issue_id, outcome})
      catch
        :exit, reason -> {:error, {:lifecycle_marker_failed, reason}}
      end
    end
  end

  defp mark_lifecycle_finishing(_recipient, _issue, _outcome), do: :ok

  defp run_phased_execution(workspace, issue, codex_update_recipient, opts) do
    settings = Config.settings!().agent
    verification_command = settings.verification_command
    lifecycle_opts = lifecycle_opts(opts)

    with true <-
           (is_binary(verification_command) and String.trim(verification_command) != "") or
             {:error, :missing_verification_command},
         {:ok, lifecycle} <- Lifecycle.start(issue, workspace, lifecycle_opts) do
      try do
        result =
          with {:ok, app_session} <- AppServer.start_session(workspace),
               {:ok, collector} <- Agent.start_link(fn -> [] end) do
            try do
              pipeline = %{
                verification_command: verification_command,
                settings: settings,
                opts: opts
              }

              run_phases(
                app_session,
                workspace,
                issue,
                lifecycle,
                collector,
                codex_update_recipient,
                pipeline
              )
            after
              AppServer.stop_session(app_session)

              if Process.alive?(collector) do
                Agent.stop(collector)
              end
            end
          end

        case result do
          {:error, reason} = error ->
            _ =
              finish_lifecycle(
                lifecycle,
                issue,
                codex_update_recipient,
                :blocked,
                "Host pipeline failed: #{inspect(reason)}"
              )

            error

          other ->
            other
        end
      rescue
        exception ->
          _ =
            finish_lifecycle(
              lifecycle,
              issue,
              codex_update_recipient,
              :blocked,
              "Host pipeline crashed: #{Exception.message(exception)}"
            )

          reraise exception, __STACKTRACE__
      end
    else
      {:error, _reason} = error -> error
    end
  end

  defp run_phases(
         app_session,
         workspace,
         issue,
         lifecycle,
         collector,
         recipient,
         pipeline
       ) do
    capsule =
      TaskCapsule.build(issue, workspace,
        branch: lifecycle.branch,
        verification_command: pipeline.verification_command,
        attempt: Keyword.get(pipeline.opts, :attempt)
      )

    with {:ok, publication_base} <- publication_base(issue),
         {:ok, implementation} <-
           run_phase(app_session, capsule, issue, :implementation, collector, recipient),
         :ok <- compact_phase(app_session, recipient, issue),
         {:ok, diff} <- diff_summary(workspace, publication_base),
         {:ok, verification} <-
           run_host_verification(
             workspace,
             issue,
             recipient,
             pipeline
           ),
         {:ok, lifecycle} <- Lifecycle.record_verification(lifecycle, verification),
         {:ok, _interpretation} <-
           run_phase(
             app_session,
             TaskCapsule.phase_handoff(:verification, %{
               changed_paths: diff.changed_paths,
               rationale: implementation.last_message,
               diff_status: diff.status,
               verification: verification
             }),
             issue,
             :verification,
             collector,
             recipient
           ),
         :ok <- compact_phase(app_session, recipient, issue),
         {:ok, publication} <-
           run_phase(
             app_session,
             TaskCapsule.phase_handoff(:publication, %{
               changed_paths: diff.changed_paths,
               verification: verification,
               base_branch: publication_base
             }),
             issue,
             :publication,
             collector,
             recipient
           ) do
      finalize_phased_run(
        lifecycle,
        issue,
        workspace,
        verification,
        diff,
        publication,
        publication_base,
        Keyword.put(pipeline.opts, :lifecycle_recipient, recipient)
      )
    end
  end

  defp run_phase(app_session, prompt, issue, phase, collector, recipient) do
    send_worker_phase(recipient, issue, phase)
    message_count_before = Agent.get(collector, &length/1)

    handler = phased_codex_message_handler(recipient, issue, phase, collector)

    case AppServer.run_turn(app_session, prompt, issue, on_message: handler) do
      {:ok, turn_session} ->
        messages = Agent.get(collector, &Enum.drop(&1, message_count_before))

        {:ok,
         %{
           session_id: turn_session.session_id,
           last_message: List.last(messages) || "No completed agent message captured."
         }}

      {:error, _reason} = error ->
        error
    end
  end

  defp run_host_verification(workspace, issue, recipient, pipeline) do
    send_worker_phase(recipient, issue, :verification)
    send_host_wait(recipient, issue, true)

    try do
      CommandWaiter.run(
        workspace,
        pipeline.verification_command,
        Keyword.merge(
          [timeout_ms: pipeline.settings.verification_timeout_ms],
          Keyword.get(pipeline.opts, :command_waiter_opts, [])
        )
      )
    after
      send_host_wait(recipient, issue, false)
    end
  end

  defp finalize_phased_run(
         lifecycle,
         issue,
         workspace,
         verification,
         diff,
         publication,
         publication_base,
         opts
       ) do
    recipient = Keyword.fetch!(opts, :lifecycle_recipient)

    case Delivery.parse_declaration(publication.last_message) do
      {:ok, declaration} ->
        finalize_declared_delivery(
          lifecycle,
          issue,
          workspace,
          verification,
          diff,
          declaration,
          publication_base,
          opts
        )

      {:error, reason} ->
        finish_blocked(
          lifecycle,
          issue,
          recipient,
          "Invalid delivery declaration: #{inspect(reason)}"
        )
    end
  end

  defp finalize_declared_delivery(
         lifecycle,
         issue,
         _workspace,
         _verification,
         _diff,
         %{outcome: :blocked, summary: summary},
         _publication_base,
         opts
       ) do
    recipient = Keyword.fetch!(opts, :lifecycle_recipient)
    finish_blocked(lifecycle, issue, recipient, summary)
  end

  defp finalize_declared_delivery(
         lifecycle,
         issue,
         workspace,
         verification,
         diff,
         %{outcome: :ready} = declaration,
         publication_base,
         opts
       ) do
    recipient = Keyword.fetch!(opts, :lifecycle_recipient)

    delivery_opts = [
      expected_base: publication_base,
      authorized_paths: TaskCapsule.authorized_paths(issue)
    ]

    delivery_opts =
      case Keyword.get(opts, :delivery_command) do
        command when is_function(command, 3) -> Keyword.put(delivery_opts, :command, command)
        _ -> delivery_opts
      end

    with {:ok, delivery} <-
           Delivery.deliver(
             lifecycle,
             issue,
             workspace,
             verification,
             diff,
             declaration,
             delivery_opts
           ),
         {:ok, lifecycle} <- Lifecycle.record_delivery(lifecycle, delivery),
         {:ok, _lifecycle} <-
           finish_lifecycle(
             lifecycle,
             issue,
             recipient,
             :ready,
             "Verification passed and PR ##{delivery.number} is ready for human review."
           ) do
      :ok
    else
      {:error, reason} ->
        finish_blocked(lifecycle, issue, recipient, "Host delivery failed: #{inspect(reason)}")
    end
  end

  defp finish_blocked(lifecycle, issue, recipient, summary) do
    with {:ok, _lifecycle} <-
           finish_lifecycle(lifecycle, issue, recipient, :blocked, summary),
         do: :ok
  end

  defp finish_lifecycle(%{enabled: true} = lifecycle, issue, recipient, outcome, summary) do
    with :ok <- mark_lifecycle_finishing(recipient, issue, outcome) do
      Lifecycle.finish(lifecycle, outcome, summary)
    end
  end

  defp finish_lifecycle(lifecycle, _issue, _recipient, outcome, summary) do
    Lifecycle.finish(lifecycle, outcome, summary)
  end

  defp publication_base(issue) do
    configured_base =
      Config.settings!().tracker.provider
      |> Map.get("delivery_base_ref", "main")
      |> to_string()
      |> String.trim()

    case TaskCapsule.publication_base(issue) do
      nil -> {:ok, configured_base}
      ^configured_base -> {:ok, configured_base}
      _other -> {:error, :publication_base_mismatch}
    end
  end

  defp diff_summary(workspace, publication_base) do
    case System.cmd("git", ["status", "--porcelain"], cd: workspace, stderr_to_stdout: true) do
      {output, 0} ->
        worktree_paths =
          output
          |> String.split("\n", trim: true)
          |> Enum.map(&String.slice(&1, 3..-1//1))
          |> Enum.reject(&is_nil/1)

        committed_paths = committed_paths(workspace, publication_base)
        changed_paths = Enum.uniq(worktree_paths ++ committed_paths)

        {:ok,
         %{
           changed_paths: changed_paths,
           status: diff_status(worktree_paths, committed_paths)
         }}

      {output, status} ->
        {:error, {:git_status_failed, status, String.slice(output, 0, 1_000)}}
    end
  end

  defp committed_paths(workspace, publication_base) do
    ["origin/#{publication_base}", publication_base]
    |> Enum.find_value([], fn candidate ->
      case System.cmd(
             "git",
             ["rev-parse", "--verify", "--quiet", candidate],
             cd: workspace,
             stderr_to_stdout: true
           ) do
        {_output, 0} -> git_changed_paths(workspace, candidate)
        _ -> nil
      end
    end)
  end

  defp git_changed_paths(workspace, base_ref) do
    case System.cmd(
           "git",
           ["diff", "--name-only", "#{base_ref}...HEAD", "--"],
           cd: workspace,
           stderr_to_stdout: true
         ) do
      {output, 0} -> String.split(output, "\n", trim: true)
      _ -> []
    end
  end

  defp diff_status([_ | _], _committed_paths), do: "dirty"
  defp diff_status([], [_ | _]), do: "committed"
  defp diff_status([], []), do: "clean"

  defp collect_agent_message(collector, message) do
    case completed_agent_message(message) do
      text when is_binary(text) and text != "" ->
        Agent.update(collector, fn messages -> (messages ++ [text]) |> Enum.take(-20) end)

      _ ->
        :ok
    end
  end

  defp completed_agent_message(message) do
    payload = message[:payload] || %{}
    method = payload["method"] || payload[:method]

    if method in ["item/completed", "codex/event/agent_message"] do
      get_in(payload, ["params", "item", "text"]) ||
        get_in(payload, ["params", "msg", "message"]) ||
        get_in(payload, ["params", "msg", "text"])
    else
      nil
    end
  end

  defp phased_execution?(%Issue{native_ref: %{"repo" => repo}}, nil) when is_binary(repo) do
    Config.settings!().agent.phased_execution
  end

  defp phased_execution?(_issue, _worker_host), do: false

  defp lifecycle_opts(opts) do
    [
      request: Keyword.get(opts, :lifecycle_request),
      command: Keyword.get(opts, :lifecycle_command)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp compact_phase(app_session, recipient, %Issue{id: issue_id} = issue) do
    with :ok <- AppServer.compact_session(app_session) do
      if is_pid(recipient) and is_binary(issue_id) do
        send(recipient, {:worker_compacted, issue_id})
      end

      send_worker_phase(recipient, issue, :compaction)
      :ok
    end
  end

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issues_by_ids/1)

    with {:ok, session} <- AppServer.start_session(workspace, worker_host: worker_host) do
      try do
        do_run_codex_turns(session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, 1, max_turns)
      after
        AppServer.stop_session(session)
      end
    end
  end

  defp do_run_codex_turns(app_session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, turn_number, max_turns) do
    prompt = build_turn_prompt(issue, opts, turn_number, max_turns)

    with {:ok, turn_session} <-
           AppServer.run_turn(
             app_session,
             prompt,
             issue,
             on_message: codex_message_handler(codex_update_recipient, issue)
           ) do
      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

      case continue_with_issue?(issue, issue_state_fetcher) do
        {:continue, refreshed_issue} when turn_number < max_turns ->
          Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

          do_run_codex_turns(
            app_session,
            workspace,
            refreshed_issue,
            codex_update_recipient,
            opts,
            issue_state_fetcher,
            turn_number + 1,
            max_turns
          )

        {:continue, refreshed_issue} ->
          Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")

          :ok

        {:done, _refreshed_issue} ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns), do: PromptBuilder.build_prompt(issue, opts)

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous Codex turn completed normally, but the tracker work item is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) and issue_routable?(refreshed_issue) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp issue_routable?(%Issue{} = issue) do
    Issue.routable?(issue, Config.settings!().tracker.required_labels)
  end

  defp selected_worker_host(nil, []), do: nil

  defp selected_worker_host(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" -> host
      _ when hosts == [] -> nil
      _ -> List.first(hosts)
    end
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
