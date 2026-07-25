defmodule SymphonyElixir.GitHub.Lifecycle do
  @moduledoc """
  Host-owned GitHub lifecycle mechanics for phased autonomous runs.

  This module prepares the issue branch, manages lifecycle labels, maintains one
  workpad comment, and attaches bounded verification evidence without involving
  the model.
  """

  alias SymphonyElixir.GitHub.Client
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.WorkerToolchain

  @workpad_marker "## Symphony Workpad"
  @running_label "agent-running"
  @ready_label "agent-ready"
  @blocked_label "agent-blocked"
  @review_label "human-review"

  @type context :: %{
          enabled: boolean(),
          issue_number: pos_integer() | nil,
          repo: String.t() | nil,
          branch: String.t(),
          workpad_comment_id: integer() | nil,
          workpad_url: String.t() | nil,
          workpad_body: String.t(),
          request: function()
        }

  @spec start(Issue.t(), Path.t(), keyword()) :: {:ok, context()} | {:error, term()}
  def start(%Issue{} = issue, workspace, opts \\ [])
      when is_binary(workspace) and is_list(opts) do
    request = Keyword.get(opts, :request, &request/4)
    command = Keyword.get(opts, :command, &command/3)

    with {:ok, issue_number, repo} <- issue_identity(issue),
         {:ok, branch} <- prepare_branch(workspace, issue.identifier, command),
         :ok <- ensure_rg(workspace, command),
         :ok <- add_labels(request, repo, issue_number, [@running_label]),
         :ok <- remove_labels(request, repo, issue_number, [@ready_label, @blocked_label, @review_label]),
         {:ok, comment} <- ensure_workpad(request, repo, issue_number, issue, branch) do
      {:ok,
       %{
         enabled: true,
         issue_number: issue_number,
         repo: repo,
         branch: branch,
         workpad_comment_id: comment.id,
         workpad_url: comment.url,
         workpad_body: comment.body,
         request: request
       }}
    end
  end

  @spec record_verification(context(), map()) :: {:ok, context()} | {:error, term()}
  def record_verification(%{enabled: true} = context, verification) when is_map(verification) do
    body =
      context.workpad_body <>
        """


        ### Host verification

        - Command: `#{verification.command}`
        - Status: `#{verification.status}`
        - Duration: #{verification.duration_ms} ms
        - Exit code: #{inspect(verification.exit_code)}
        - Passed stages: #{join_or_none(verification.passed_stages)}
        - Failed stages: #{join_or_none(verification.failed_stages)}
        - Full log artifact: `#{verification.log_path}`

        Relevant output:

        ```
        #{Enum.join(verification.relevant_lines, "\n")}
        ```
        """

    update_workpad(context, body)
  end

  def record_verification(context, _verification), do: {:ok, context}

  @spec finish(context(), :ready | :blocked, String.t()) :: {:ok, context()} | {:error, term()}
  def finish(%{enabled: true} = context, outcome, summary)
      when outcome in [:ready, :blocked] and is_binary(summary) do
    label = if outcome == :ready, do: @review_label, else: @blocked_label

    body =
      context.workpad_body <>
        """


        ### Declared outcome

        - Outcome: `#{String.upcase(to_string(outcome))}`
        - Summary: #{summary}
        """

    with {:ok, context} <- update_workpad(context, body),
         :ok <- add_labels(context.request, context.repo, context.issue_number, [label]),
         :ok <-
           remove_labels(context.request, context.repo, context.issue_number, [
             @running_label,
             @ready_label,
             if(outcome == :ready, do: @blocked_label, else: @review_label)
           ]) do
      {:ok, context}
    end
  end

  def finish(context, _outcome, _summary), do: {:ok, context}

  @doc """
  Performs best-effort blocked-state cleanup when a run is stopped outside the
  normal three-phase pipeline, such as by a host token circuit breaker.
  """
  @spec block_issue(Issue.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def block_issue(%Issue{} = issue, summary, opts \\ [])
      when is_binary(summary) and is_list(opts) do
    request = Keyword.get(opts, :request, &request/4)

    with {:ok, issue_number, repo} <- issue_identity(issue),
         :ok <- add_labels(request, repo, issue_number, [@blocked_label]),
         :ok <- remove_labels(request, repo, issue_number, [@running_label, @ready_label, @review_label]) do
      append_blocked_reason(request, repo, issue_number, summary)
      :ok
    end
  end

  @spec find_pull_request(context()) :: {:ok, map() | nil} | {:error, term()}
  def find_pull_request(%{enabled: true} = context) do
    owner = context.repo |> String.split("/", parts: 2) |> hd()

    case context.request.(
           "GET",
           "/repos/#{context.repo}/pulls",
           %{"state" => "open", "head" => "#{owner}:#{context.branch}"},
           nil
         ) do
      {:ok, %{status: status, body: [pull | _]}} when status in 200..299 and is_map(pull) ->
        {:ok,
         %{
           number: pull["number"],
           state: pull["state"],
           draft: pull["draft"],
           url: pull["html_url"]
         }}

      {:ok, %{status: status, body: []}} when status in 200..299 ->
        {:ok, nil}

      other ->
        {:error, {:pull_lookup_failed, other}}
    end
  end

  def find_pull_request(_context), do: {:ok, nil}

  defp issue_identity(%Issue{id: id, native_ref: %{"repo" => repo}})
       when is_binary(id) and is_binary(repo) do
    case Integer.parse(id) do
      {number, ""} when number > 0 -> {:ok, number, repo}
      _ -> {:error, :invalid_github_issue_number}
    end
  end

  defp issue_identity(_issue), do: {:error, :github_lifecycle_requires_native_ref}

  defp prepare_branch(workspace, identifier, command) do
    with {:ok, current} <- command.(workspace, "git branch --show-current", []),
         branch <- String.trim(current) do
      ensure_feature_branch(workspace, branch, identifier, command)
    end
  end

  defp ensure_feature_branch(workspace, branch, identifier, command)
       when branch in ["", "main", "master"] do
    desired = "codex/symphony-#{slug(identifier)}"

    case command.(workspace, "git switch -c #{desired}", []) do
      {:ok, _output} -> {:ok, desired}
      {:error, reason} -> {:error, {:branch_prepare_failed, reason}}
    end
  end

  defp ensure_feature_branch(_workspace, branch, _identifier, _command), do: {:ok, branch}

  defp ensure_rg(workspace, command) do
    case command.(workspace, "command -v rg", WorkerToolchain.command_env()) do
      {:ok, path} when is_binary(path) ->
        if String.trim(path) == "", do: {:error, :rg_not_found}, else: :ok

      _ ->
        {:error, :rg_not_found}
    end
  end

  defp ensure_workpad(request, repo, issue_number, issue, branch) do
    path = "/repos/#{repo}/issues/#{issue_number}/comments"

    case request.("GET", path, %{"per_page" => 100}, nil) do
      {:ok, %{status: status, body: comments}} when status in 200..299 and is_list(comments) ->
        case Enum.find(comments, &workpad_comment?/1) do
          %{} = comment ->
            {:ok, comment_context(comment)}

          nil ->
            create_workpad(request, path, issue, branch)
        end

      other ->
        {:error, {:workpad_lookup_failed, other}}
    end
  end

  defp create_workpad(request, path, issue, branch) do
    body = initial_workpad(issue, branch)

    case request.("POST", path, %{}, %{"body" => body}) do
      {:ok, %{status: status, body: comment}} when status in 200..299 and is_map(comment) ->
        {:ok, comment_context(Map.put(comment, "body", body))}

      other ->
        {:error, {:workpad_create_failed, other}}
    end
  end

  defp append_blocked_reason(request, repo, issue_number, summary) do
    path = "/repos/#{repo}/issues/#{issue_number}/comments"

    with {:ok, %{status: status, body: comments}} when status in 200..299 and is_list(comments) <-
           request.("GET", path, %{"per_page" => 100}, nil),
         %{} = comment <- Enum.find(comments, &workpad_comment?/1),
         comment_id when is_integer(comment_id) <- comment["id"] do
      body =
        (comment["body"] || @workpad_marker) <>
          """


          ### Host circuit breaker

          - Outcome: `BLOCKED`
          - Reason: #{summary}
          """

      request.("PATCH", "/repos/#{repo}/issues/comments/#{comment_id}", %{}, %{"body" => body})
    else
      _ -> :ok
    end

    :ok
  end

  defp update_workpad(context, body) do
    path = "/repos/#{context.repo}/issues/comments/#{context.workpad_comment_id}"

    case context.request.("PATCH", path, %{}, %{"body" => body}) do
      {:ok, %{status: status}} when status in 200..299 ->
        {:ok, %{context | workpad_body: body}}

      other ->
        {:error, {:workpad_update_failed, other}}
    end
  end

  defp add_labels(request, repo, issue_number, labels) do
    case request.(
           "POST",
           "/repos/#{repo}/issues/#{issue_number}/labels",
           %{},
           %{"labels" => labels}
         ) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      other -> {:error, {:label_add_failed, labels, other}}
    end
  end

  defp remove_labels(request, repo, issue_number, labels) do
    Enum.reduce_while(labels, :ok, fn label, :ok ->
      path = "/repos/#{repo}/issues/#{issue_number}/labels/#{URI.encode(label)}"

      case request.("DELETE", path, %{}, nil) do
        {:ok, %{status: status}} when status in 200..299 or status == 404 -> {:cont, :ok}
        other -> {:halt, {:error, {:label_remove_failed, label, other}}}
      end
    end)
  end

  defp workpad_comment?(%{"body" => body}) when is_binary(body) do
    String.starts_with?(String.trim_leading(body), @workpad_marker)
  end

  defp workpad_comment?(_comment), do: false

  defp comment_context(comment) do
    %{
      id: comment["id"],
      url: comment["html_url"],
      body: comment["body"] || @workpad_marker
    }
  end

  defp initial_workpad(issue, branch) do
    """
    #{@workpad_marker}

    ### Host lifecycle

    - Issue: #{issue.identifier}
    - Branch: `#{branch}`
    - Phase: `implementation`
    - Lifecycle labels and verification are managed by Symphony.

    ### Verification

    Pending host-side verification.
    """
    |> String.trim()
  end

  defp join_or_none([]), do: "none"
  defp join_or_none(values), do: Enum.join(values, ", ")

  defp slug(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp request(method, path, params, body), do: Client.request(method, path, params, body)

  defp command(workspace, shell_command, env) do
    case System.cmd("bash", ["-lc", shell_command], cd: workspace, env: env, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, %{status: status, output: String.slice(output, 0, 2_000)}}
    end
  end
end
