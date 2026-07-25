defmodule SymphonyElixir.GitHub.Delivery do
  @moduledoc """
  Performs the bounded, idempotent Git and GitHub delivery transaction for a
  verified phased run.
  """

  alias SymphonyElixir.Tracker.Issue

  @conventional_commit ~r/^(feat|fix|test|docs|chore|refactor):\s+\S/
  @delivery_pattern ~r/^SYMPHONY_DELIVERY:\s*(\{.*\})\s*$/m

  @type declaration :: %{
          outcome: :ready | :blocked,
          commit_message: String.t() | nil,
          pr_title: String.t() | nil,
          summary: String.t()
        }

  @type result :: %{
          number: pos_integer(),
          state: String.t(),
          url: String.t(),
          branch: String.t(),
          base: String.t(),
          changed_paths: [String.t()]
        }

  @spec parse_declaration(String.t()) :: {:ok, declaration()} | {:error, term()}
  def parse_declaration(message) when is_binary(message) do
    with [json] <- Regex.run(@delivery_pattern, message, capture: :all_but_first),
         {:ok, payload} when is_map(payload) <- Jason.decode(json) do
      normalize_declaration(payload)
    else
      _ -> {:error, :missing_delivery_declaration}
    end
  end

  @spec deliver(map(), Issue.t(), Path.t(), map(), map(), declaration(), keyword()) ::
          {:ok, result()} | {:error, term()}
  def deliver(context, %Issue{} = issue, workspace, verification, diff, declaration, opts \\ [])
      when is_map(context) and is_binary(workspace) and is_map(verification) and is_map(diff) and
             is_map(declaration) and is_list(opts) do
    command = Keyword.get(opts, :command, &git_command/3)
    expected_base = Keyword.fetch!(opts, :expected_base)
    authorized_paths = Keyword.fetch!(opts, :authorized_paths)

    with :ok <- validate_ready_declaration(declaration),
         :ok <- validate_verification(verification),
         :ok <- validate_context(context, expected_base),
         {:ok, actual_paths} <-
           validate_repository(
             workspace,
             context.branch,
             expected_base,
             diff,
             authorized_paths,
             command
           ),
         :ok <- commit_if_needed(workspace, actual_paths, declaration.commit_message, command),
         :ok <- push_branch(workspace, context.branch, command),
         {:ok, pull} <-
           create_or_update_pull(
             context,
             issue,
             expected_base,
             declaration,
             verification,
             actual_paths
           ) do
      {:ok,
       %{
         number: pull.number,
         state: pull.state,
         url: pull.url,
         branch: context.branch,
         base: expected_base,
         changed_paths: actual_paths
       }}
    end
  end

  defp normalize_declaration(%{"outcome" => "blocked"} = payload) do
    with {:ok, summary} <- required_text(payload["reason"] || payload["summary"], :missing_blocked_reason) do
      {:ok, %{outcome: :blocked, commit_message: nil, pr_title: nil, summary: summary}}
    end
  end

  defp normalize_declaration(%{"outcome" => "ready"} = payload) do
    with {:ok, commit_message} <- required_text(payload["commit_message"], :missing_commit_message),
         true <- Regex.match?(@conventional_commit, commit_message) or {:error, :invalid_commit_message},
         {:ok, pr_title} <- required_text(payload["pr_title"], :missing_pr_title),
         {:ok, summary} <- required_text(payload["summary"], :missing_delivery_summary) do
      {:ok,
       %{
         outcome: :ready,
         commit_message: commit_message,
         pr_title: pr_title,
         summary: summary
       }}
    end
  end

  defp normalize_declaration(_payload), do: {:error, :invalid_delivery_outcome}

  defp required_text(value, error) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, error}
      text -> {:ok, text}
    end
  end

  defp required_text(_value, error), do: {:error, error}

  defp validate_ready_declaration(%{outcome: :ready}), do: :ok
  defp validate_ready_declaration(_declaration), do: {:error, :delivery_not_ready}

  defp validate_verification(%{
         status: :passed,
         exit_code: 0,
         log_path: log_path
       })
       when is_binary(log_path) do
    if File.regular?(log_path), do: :ok, else: {:error, :missing_verification_artifact}
  end

  defp validate_verification(_verification), do: {:error, :verification_not_passed}

  defp validate_context(%{branch: branch, request: request}, expected_base)
       when is_binary(branch) and is_binary(expected_base) and is_function(request, 4),
       do: :ok

  defp validate_context(_context, _expected_base), do: {:error, :invalid_delivery_context}

  defp validate_repository(
         workspace,
         expected_branch,
         expected_base,
         diff,
         authorized_paths,
         command
       ) do
    with {:ok, branch} <- command.(workspace, ["branch", "--show-current"], []),
         true <- String.trim(branch) == expected_branch or {:error, :branch_mismatch},
         {:ok, actual_paths} <- changed_paths(workspace, expected_base, command),
         :ok <- validate_changed_paths(actual_paths, diff, authorized_paths) do
      {:ok, actual_paths}
    end
  end

  defp changed_paths(workspace, base, command) do
    with {:ok, committed} <-
           command.(workspace, ["diff", "--name-only", "origin/#{base}...HEAD", "--"], []),
         {:ok, unstaged} <- command.(workspace, ["diff", "--name-only", "--"], []),
         {:ok, staged} <- command.(workspace, ["diff", "--cached", "--name-only", "--"], []),
         {:ok, untracked} <-
           command.(workspace, ["ls-files", "--others", "--exclude-standard"], []) do
      paths =
        [committed, unstaged, staged, untracked]
        |> Enum.flat_map(&String.split(&1, "\n", trim: true))
        |> Enum.uniq()
        |> Enum.sort()

      {:ok, paths}
    end
  end

  defp validate_changed_paths([], _diff, _authorized_paths), do: {:error, :no_changed_paths}

  defp validate_changed_paths(actual_paths, diff, authorized_paths) do
    declared_paths = diff |> Map.get(:changed_paths, []) |> Enum.sort()
    allowed = MapSet.new(authorized_paths)

    cond do
      actual_paths != declared_paths -> {:error, :changed_paths_mismatch}
      MapSet.size(allowed) == 0 -> {:error, :missing_authorized_paths}
      Enum.any?(actual_paths, &(not MapSet.member?(allowed, &1))) -> {:error, :out_of_scope_path}
      true -> :ok
    end
  end

  defp commit_if_needed(workspace, paths, message, command) do
    case command.(workspace, ["status", "--porcelain"], []) do
      {:ok, status} -> commit_dirty_paths(workspace, paths, message, command, status)
      {:error, _reason} = error -> error
    end
  end

  defp commit_dirty_paths(_workspace, _paths, _message, _command, status)
       when status in ["", "\n"],
       do: :ok

  defp commit_dirty_paths(workspace, paths, message, command, _status) do
    with {:ok, _output} <- command.(workspace, ["add", "--" | paths], []),
         {:ok, _output} <- command.(workspace, ["commit", "-m", message], []) do
      :ok
    end
  end

  defp push_branch(workspace, branch, command) do
    case command.(workspace, ["push", "--set-upstream", "origin", branch], []) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, {:push_failed, reason}}
    end
  end

  defp create_or_update_pull(context, issue, base, declaration, verification, paths) do
    body = pull_body(issue, declaration.summary, verification, paths)
    owner = context.repo |> String.split("/", parts: 2) |> hd()
    pulls_path = "/repos/#{context.repo}/pulls"
    params = %{"state" => "open", "head" => "#{owner}:#{context.branch}", "base" => base}

    case context.request.("GET", pulls_path, params, nil) do
      {:ok, %{status: status, body: pulls}} when status in 200..299 and is_list(pulls) ->
        upsert_pull(context, pulls_path, List.first(pulls), base, declaration, body)

      other ->
        {:error, {:pull_lookup_failed, other}}
    end
  end

  defp upsert_pull(context, pulls_path, nil, base, declaration, body) do
    payload = %{
      "head" => context.branch,
      "base" => base,
      "title" => declaration.pr_title,
      "body" => body
    }

    project_pull(context.request.("POST", pulls_path, %{}, payload))
  end

  defp upsert_pull(context, _pulls_path, %{"number" => number}, base, declaration, body)
       when is_integer(number) do
    payload = %{"base" => base, "title" => declaration.pr_title, "body" => body}
    path = "/repos/#{context.repo}/pulls/#{number}"
    project_pull(context.request.("PATCH", path, %{}, payload))
  end

  defp upsert_pull(_context, _pulls_path, _pull, _base, _declaration, _body),
    do: {:error, :invalid_pull_response}

  defp project_pull({:ok, %{status: status, body: pull}})
       when status in 200..299 and is_map(pull) do
    with number when is_integer(number) <- pull["number"],
         state when is_binary(state) <- pull["state"],
         url when is_binary(url) <- pull["html_url"] do
      {:ok, %{number: number, state: state, url: url}}
    else
      _ -> {:error, :invalid_pull_response}
    end
  end

  defp project_pull(other), do: {:error, {:pull_write_failed, other}}

  defp pull_body(issue, summary, verification, paths) do
    path_bullets =
      Enum.map_join(paths, "\n", fn path ->
        "- " <> truncate("Update `#{path}`.", 118)
      end)

    """
    #### Context

    #{truncate("Resolves #{issue.identifier}: #{issue.title}", 240)}

    #### TL;DR

    *#{truncate(summary, 120)}*

    #### Summary

    #{path_bullets}

    #### Alternatives

    - Keep model-owned Git and GitHub mechanics; rejected to reduce context and retry ambiguity.

    #### Test Plan

    - [x] `#{verification.command}`
    - [x] Host verification exited 0; full log: `#{verification.log_path}`
    """
    |> String.trim()
  end

  defp truncate(value, limit) do
    value
    |> to_string()
    |> String.replace(~r/\s+/, " ")
    |> String.slice(0, limit)
  end

  defp git_command(workspace, arguments, env) do
    case System.cmd("git", arguments,
           cd: workspace,
           env: env,
           stderr_to_stdout: true
         ) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, %{status: status, output: String.slice(output, 0, 2_000)}}
    end
  end
end
