defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}

  @runtime_tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:payload, load_payload())
      |> assign(:now, DateTime.utc_now())

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply,
     socket
     |> assign(:payload, load_payload())
     |> assign(:now, DateTime.utc_now())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">Symphony Observability</p>
            <h1 class="hero-title">Operations Dashboard</h1>
            <p class="hero-copy">
              Live work, completed runs, account capacity, and cache-aware Codex usage.
            </p>
          </div>

          <div class="status-stack">
            <span class="status-badge status-badge-live">
              <span class="status-badge-dot"></span>
              Live
            </span>
            <span class="status-badge status-badge-offline">
              <span class="status-badge-dot"></span>
              Offline
            </span>
            <span class="freshness-label numeric">Updated <%= relative_time(@payload.generated_at, @now) %></span>
          </div>
        </div>
      </header>

      <%= if @payload[:error] do %>
        <section class="error-card" role="alert">
          <h2 class="error-title">Orchestrator state unavailable</h2>
          <p class="error-copy">
            <strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %>
          </p>
        </section>
      <% else %>
        <section class="metric-grid" aria-label="Runtime overview">
          <article class="metric-card">
            <p class="metric-label">Running</p>
            <p class="metric-value numeric"><%= @payload.counts.running %></p>
            <p class="metric-detail">Active issue sessions.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Needs attention</p>
            <p class="metric-value numeric"><%= @payload.counts.blocked + @payload.counts.retrying %></p>
            <p class="metric-detail">
              <%= @payload.counts.blocked %> blocked · <%= @payload.counts.retrying %> retrying
            </p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Run history</p>
            <p class="metric-value numeric"><%= @payload.counts.history %></p>
            <p class="metric-detail">
              <%= @payload.counts.completed %> completed · retained across restarts
            </p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Processed tokens</p>
            <p class="metric-value numeric"><%= format_int(@payload.codex_totals.total_tokens) %></p>
            <p class="metric-detail numeric">
              <%= format_int(@payload.codex_totals.uncached_input_tokens) %> new context ·
              <%= format_int(@payload.codex_totals.output_tokens) %> output
            </p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Cache reuse</p>
            <p class="metric-value numeric"><%= format_percent(cache_ratio(@payload.codex_totals)) %></p>
            <p class="metric-detail numeric">
              <%= format_int(@payload.codex_totals.cached_input_tokens) %> of
              <%= format_int(@payload.codex_totals.input_tokens) %> input tokens
            </p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Agent runtime</p>
            <p class="metric-value numeric">
              <%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %>
            </p>
            <p class="metric-detail">Completed and active sessions.</p>
          </article>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Account rate limits</h2>
              <p class="section-copy">
                Polled directly from <code>account/rateLimits/read</code> every minute.
              </p>
            </div>
            <div class={rate_limit_status_class(@payload.rate_limits_status.status)}>
              <span class="status-badge-dot"></span>
              <%= rate_limit_status_label(@payload.rate_limits_status.status) %>
            </div>
          </div>

          <%= if rate_limit_entries(@payload) == [] do %>
            <p class="empty-state">
              <%= @payload.rate_limits_status.error || "Waiting for the first account response." %>
            </p>
          <% else %>
            <div class="quota-grid">
              <article :for={limit <- rate_limit_entries(@payload)} class="quota-card">
                <div class="quota-heading">
                  <div>
                    <p class="quota-name"><%= limit.name %></p>
                    <p class="muted mono"><%= limit.id %></p>
                  </div>
                  <strong class="quota-value numeric"><%= format_percent(limit.used_percent) %> used</strong>
                </div>
                <div
                  class="quota-track"
                  role="progressbar"
                  aria-label={"#{limit.name} usage"}
                  aria-valuemin="0"
                  aria-valuemax="100"
                  aria-valuenow={limit.used_percent || 0}
                >
                  <span style={"width: #{clamp_percent(limit.used_percent)}%"}></span>
                </div>
                <p class="quota-meta">
                  Resets <%= format_unix_time(limit.resets_at) %>
                  <%= if limit.window_minutes do %>
                    · <%= format_window(limit.window_minutes) %> window
                  <% end %>
                </p>
              </article>
            </div>
            <p class="section-footnote numeric">
              Account data fetched <%= format_timestamp(@payload.rate_limits_status.updated_at) %>.
            </p>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Running sessions</h2>
              <p class="section-copy">Expand a task to inspect its agent messages and execution details.</p>
            </div>
          </div>

          <%= if @payload.running == [] do %>
            <p class="empty-state">No active sessions.</p>
          <% else %>
            <div class="task-list">
              <.running_task
                :for={entry <- @payload.running}
                entry={entry}
                now={@now}
              />
            </div>
          <% end %>
        </section>

        <section :if={@payload.blocked != [] || @payload.retrying != []} class="section-card attention-section">
          <div class="section-header">
            <div>
              <h2 class="section-title">Needs attention</h2>
              <p class="section-copy">Blocked work and scheduled retries stay visible here.</p>
            </div>
          </div>

          <div class="task-list">
            <details :for={entry <- @payload.blocked} class="task-card task-card-danger">
              <summary class="task-summary">
                <div class="task-identity">
                  <.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} />
                  <span class={state_badge_class(entry.state || "blocked")}>Blocked</span>
                </div>
                <span class="task-preview"><%= entry.error %></span>
                <span class="task-chevron" aria-hidden="true"></span>
              </summary>
              <div class="task-body">
                <.detail_grid
                  session_id={entry.session_id}
                  workspace_path={entry.workspace_path}
                  worker_host={entry.worker_host}
                  timestamp_label="Blocked"
                  timestamp={entry.blocked_at}
                />
                <div class="message-panel">
                  <h3>Last agent update</h3>
                  <p><%= entry.last_message || "No agent message was captured." %></p>
                </div>
              </div>
            </details>

            <details :for={entry <- @payload.retrying} class="task-card task-card-warning">
              <summary class="task-summary">
                <div class="task-identity">
                  <.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} />
                  <span class="state-badge state-badge-warning">Retry <%= entry.attempt %></span>
                </div>
                <span class="task-preview"><%= entry.error %></span>
                <span class="task-chevron" aria-hidden="true"></span>
              </summary>
              <div class="task-body">
                <.detail_grid
                  workspace_path={entry.workspace_path}
                  worker_host={entry.worker_host}
                  timestamp_label="Retry due"
                  timestamp={entry.due_at}
                />
              </div>
            </details>
          </div>
        </section>

        <section class="section-card completed-section">
          <div class="section-header">
            <div>
              <h2 class="section-title">Run history</h2>
              <p class="section-copy">
                The latest 100 completed and blocked runs, newest first. Repeated attempts remain separate.
              </p>
            </div>
          </div>

          <%= if @payload.history == [] do %>
            <p class="empty-state">No terminal runs recorded yet.</p>
          <% else %>
            <div class="task-list">
              <.history_task :for={entry <- @payload.history} entry={entry} />
            </div>
          <% end %>
        </section>
      <% end %>
    </section>
    """
  end

  attr(:entry, :map, required: true)
  attr(:now, :any, required: true)

  defp running_task(assigns) do
    ~H"""
    <details
      id={"running-session-#{@entry.issue_id}"}
      class="task-card"
      data-running-session={@entry.issue_identifier}
      phx-hook="PreserveDetailsOpen"
    >
      <summary class="task-summary">
        <div class="task-identity">
          <.issue_identifier identifier={@entry.issue_identifier} url={@entry.issue_url} />
          <span class={state_badge_class(@entry.state)}><%= @entry.state %></span>
        </div>
        <span class="task-preview"><%= @entry.last_message || "Waiting for agent activity…" %></span>
        <div class="task-summary-meta numeric">
          <span><%= format_runtime_and_turns(@entry.started_at, @entry.turn_count, @now) %></span>
          <span><%= format_int(@entry.tokens.total_tokens) %> tokens</span>
        </div>
        <span class="task-chevron" aria-hidden="true"></span>
      </summary>
      <div class="task-body">
        <.token_breakdown tokens={@entry.tokens} />
        <.agent_outputs messages={@entry.agent_messages} />
        <.detail_grid
          session_id={@entry.session_id}
          workspace_path={@entry.workspace_path}
          worker_host={@entry.worker_host}
          timestamp_label="Started"
          timestamp={@entry.started_at}
        />
      </div>
    </details>
    """
  end

  attr(:entry, :map, required: true)

  defp history_task(assigns) do
    ~H"""
    <details class={history_task_class(@entry.outcome)}>
      <summary class="task-summary">
        <div class="task-identity">
          <.issue_identifier identifier={@entry.issue_identifier} url={@entry.issue_url} />
          <span class={history_badge_class(@entry.outcome)}>
            <%= history_outcome_label(@entry.outcome) %>
          </span>
        </div>
        <span class="task-preview">
          <%= List.last(@entry.agent_messages) || @entry.last_message || "Agent run completed." %>
        </span>
        <div class="task-summary-meta numeric">
          <span><%= format_runtime_seconds(@entry.runtime_seconds) %> / <%= @entry.turn_count %> turns</span>
          <span><%= format_timestamp(@entry.completed_at) %></span>
        </div>
        <span class="task-chevron" aria-hidden="true"></span>
      </summary>
      <div class="task-body">
        <.token_breakdown tokens={@entry.tokens} />
        <.agent_outputs messages={@entry.agent_messages} />
        <div :if={@entry.error} class="message-panel">
          <h3>Blocked reason</h3>
          <p><%= @entry.error %></p>
        </div>
        <.detail_grid
          session_id={@entry.session_id}
          workspace_path={@entry.workspace_path}
          worker_host={@entry.worker_host}
          timestamp_label={history_timestamp_label(@entry.outcome)}
          timestamp={@entry.completed_at}
        />
      </div>
    </details>
    """
  end

  attr(:tokens, :map, required: true)

  defp token_breakdown(assigns) do
    ~H"""
    <div class="token-breakdown" aria-label="Token usage">
      <div>
        <span class="token-label">New context</span>
        <strong class="numeric"><%= format_int(@tokens.uncached_input_tokens) %></strong>
      </div>
      <div>
        <span class="token-label">Cached context</span>
        <strong class="numeric"><%= format_int(@tokens.cached_input_tokens) %></strong>
      </div>
      <div>
        <span class="token-label">Output</span>
        <strong class="numeric"><%= format_int(@tokens.output_tokens) %></strong>
      </div>
      <div>
        <span class="token-label">Total processed</span>
        <strong class="numeric"><%= format_int(@tokens.total_tokens) %></strong>
      </div>
    </div>
    """
  end

  attr(:messages, :list, required: true)

  defp agent_outputs(assigns) do
    ~H"""
    <section class="message-panel">
      <h3>Agent output</h3>
      <%= if @messages == [] do %>
        <p class="muted">No completed agent messages captured yet.</p>
      <% else %>
        <ol class="message-list">
          <li :for={{message, index} <- Enum.with_index(@messages, 1)}>
            <span class="message-number numeric"><%= index %></span>
            <div class="agent-message"><%= message %></div>
          </li>
        </ol>
      <% end %>
    </section>
    """
  end

  attr(:session_id, :string, default: nil)
  attr(:workspace_path, :string, default: nil)
  attr(:worker_host, :string, default: nil)
  attr(:timestamp_label, :string, required: true)
  attr(:timestamp, :string, default: nil)

  defp detail_grid(assigns) do
    ~H"""
    <dl class="detail-grid">
      <div>
        <dt>Session</dt>
        <dd class="mono"><%= @session_id || "n/a" %></dd>
      </div>
      <div>
        <dt>Worker</dt>
        <dd class="mono"><%= @worker_host || "local" %></dd>
      </div>
      <div>
        <dt><%= @timestamp_label %></dt>
        <dd class="numeric"><%= format_timestamp(@timestamp) %></dd>
      </div>
      <div class="detail-wide">
        <dt>Workspace</dt>
        <dd class="mono"><%= @workspace_path || "n/a" %></dd>
      </div>
    </dl>
    """
  end

  attr(:identifier, :string, required: true)
  attr(:url, :string, default: nil)

  defp issue_identifier(assigns) do
    assigns = assign(assigns, :href, external_issue_url(assigns.url))

    ~H"""
    <%= if @href do %>
      <a
        class="issue-id issue-id-link"
        href={@href}
        target="_blank"
        rel="noopener noreferrer"
        aria-label={"Open #{@identifier} in the issue tracker"}
      ><%= @identifier %><span aria-hidden="true"> ↗</span></a>
    <% else %>
      <span class="issue-id"><%= @identifier %></span>
    <% end %>
    """
  end

  defp load_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp rate_limit_entries(payload) do
    by_limit_id = Map.get(payload, :rate_limits_by_limit_id)

    payload
    |> raw_rate_limit_entries(by_limit_id)
    |> Enum.flat_map(&rate_limit_bucket_entries/1)
    |> Enum.sort_by(& &1.name)
  end

  defp raw_rate_limit_entries(_payload, by_limit_id)
       when is_map(by_limit_id) and map_size(by_limit_id) > 0 do
    Map.values(by_limit_id)
  end

  defp raw_rate_limit_entries(%{rate_limits: rate_limits}, _by_limit_id)
       when is_map(rate_limits) do
    [rate_limits]
  end

  defp raw_rate_limit_entries(_payload, _by_limit_id), do: []

  defp rate_limit_bucket_entries(limit) do
    id = first_map_value(limit, ["limitId", "limit_id"], "account")
    name = first_map_value(limit, ["limitName", "limit_name"], id)

    [{"primary", "Primary"}, {"secondary", "Secondary"}]
    |> Enum.flat_map(fn {bucket_key, bucket_label} ->
      case map_value(limit, bucket_key) do
        %{} = bucket ->
          [
            %{
              id: "#{id}:#{bucket_key}",
              name: "#{name} · #{bucket_label}",
              used_percent: first_map_value(bucket, ["usedPercent", "used_percent"]),
              resets_at: first_map_value(bucket, ["resetsAt", "resets_at"]),
              window_minutes: first_map_value(bucket, ["windowDurationMins", "window_duration_mins"])
            }
          ]

        _ ->
          []
      end
    end)
  end

  defp first_map_value(map, keys, default \\ nil) do
    Enum.find_value(keys, &map_value(map, &1)) || default
  end

  defp map_value(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(map, key)
  end

  defp map_value(_map, _key), do: nil

  defp external_issue_url(url) when is_binary(url) do
    url = String.trim(url)

    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        url

      _ ->
        nil
    end
  end

  defp external_issue_url(_url), do: nil

  defp completed_runtime_seconds(payload), do: payload.codex_totals.seconds_running || 0

  defp total_runtime_seconds(payload, now) do
    completed_runtime_seconds(payload) +
      Enum.reduce(payload.running, 0, fn entry, total ->
        total + runtime_seconds_from_started_at(entry.started_at, now)
      end)
  end

  defp format_runtime_and_turns(started_at, turn_count, now)
       when is_integer(turn_count) and turn_count > 0 do
    "#{format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))} / #{turn_count} turns"
  end

  defp format_runtime_and_turns(started_at, _turn_count, now) do
    format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))
  end

  defp format_runtime_seconds(seconds) when is_number(seconds) do
    total_seconds = seconds |> trunc() |> max(0)
    hours = div(total_seconds, 3_600)
    minutes = div(rem(total_seconds, 3_600), 60)
    remaining_seconds = rem(total_seconds, 60)

    cond do
      hours > 0 -> "#{hours}h #{minutes}m"
      minutes > 0 -> "#{minutes}m #{remaining_seconds}s"
      true -> "#{remaining_seconds}s"
    end
  end

  defp format_runtime_seconds(_seconds), do: "n/a"

  defp runtime_seconds_from_started_at(%DateTime{} = started_at, %DateTime{} = now) do
    max(0, DateTime.diff(now, started_at, :second))
  end

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now)
       when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> runtime_seconds_from_started_at(parsed, now)
      _ -> 0
    end
  end

  defp runtime_seconds_from_started_at(_started_at, _now), do: 0

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(_value), do: "n/a"

  defp cache_ratio(%{input_tokens: input, cached_input_tokens: cached})
       when is_number(input) and input > 0 and is_number(cached) do
    cached / input * 100
  end

  defp cache_ratio(_tokens), do: nil

  defp format_percent(value) when is_number(value), do: "#{Float.round(value * 1.0, 1)}%"
  defp format_percent(_value), do: "n/a"

  defp clamp_percent(value) when is_number(value), do: value |> max(0) |> min(100)
  defp clamp_percent(_value), do: 0

  defp format_window(minutes) when is_integer(minutes) and minutes >= 1_440 do
    "#{Float.round(minutes / 1_440, 1)}d"
  end

  defp format_window(minutes) when is_integer(minutes) and minutes >= 60 do
    "#{Float.round(minutes / 60, 1)}h"
  end

  defp format_window(minutes) when is_integer(minutes), do: "#{minutes}m"
  defp format_window(_minutes), do: "unknown"

  defp format_unix_time(seconds) when is_integer(seconds) do
    case DateTime.from_unix(seconds) do
      {:ok, timestamp} -> Calendar.strftime(timestamp, "%b %-d at %-I:%M %p UTC")
      _ -> "at an unknown time"
    end
  end

  defp format_unix_time(_seconds), do: "at an unknown time"

  defp format_timestamp(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, parsed, _offset} -> Calendar.strftime(parsed, "%b %-d, %Y · %-I:%M:%S %p UTC")
      _ -> timestamp
    end
  end

  defp format_timestamp(%DateTime{} = timestamp) do
    Calendar.strftime(timestamp, "%b %-d, %Y · %-I:%M:%S %p UTC")
  end

  defp format_timestamp(_timestamp), do: "n/a"

  defp relative_time(timestamp, %DateTime{} = now) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, parsed, _offset} ->
        case max(0, DateTime.diff(now, parsed, :second)) do
          seconds when seconds < 2 -> "just now"
          seconds when seconds < 60 -> "#{seconds}s ago"
          seconds -> "#{div(seconds, 60)}m ago"
        end

      _ ->
        "recently"
    end
  end

  defp relative_time(_timestamp, _now), do: "recently"

  defp state_badge_class(state) do
    base = "state-badge"
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["progress", "running", "active"]) ->
        "#{base} state-badge-active"

      String.contains?(normalized, ["blocked", "error", "failed"]) ->
        "#{base} state-badge-danger"

      String.contains?(normalized, ["todo", "queued", "pending", "retry"]) ->
        "#{base} state-badge-warning"

      true ->
        base
    end
  end

  defp rate_limit_status_class(status) do
    "status-badge " <>
      case status do
        status when status in [:current, "current"] -> "status-badge-live-visible"
        status when status in [:refreshing, "refreshing", :pending, "pending"] -> "state-badge-warning"
        _ -> "state-badge-danger"
      end
  end

  defp rate_limit_status_label(status) when status in [:current, "current"], do: "Current"
  defp rate_limit_status_label(status) when status in [:refreshing, "refreshing"], do: "Refreshing"
  defp rate_limit_status_label(status) when status in [:stale, "stale"], do: "Stale"
  defp rate_limit_status_label(status) when status in [:error, "error"], do: "Unavailable"
  defp rate_limit_status_label(_status), do: "Waiting"

  defp history_task_class("blocked"), do: "task-card task-card-danger"
  defp history_task_class(_outcome), do: "task-card task-card-completed"

  defp history_badge_class("blocked"), do: "state-badge state-badge-danger"
  defp history_badge_class(_outcome), do: "state-badge state-badge-completed"

  defp history_outcome_label("blocked"), do: "Run blocked"
  defp history_outcome_label(_outcome), do: "Run completed"

  defp history_timestamp_label("blocked"), do: "Blocked"
  defp history_timestamp_label(_outcome), do: "Completed"

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end
end
