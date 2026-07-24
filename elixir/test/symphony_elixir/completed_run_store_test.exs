defmodule SymphonyElixir.CompletedRunStoreTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.CompletedRunStore

  setup do
    previous_path = Application.get_env(:symphony_elixir, :completed_runs_file)
    path = Path.join(System.tmp_dir!(), "symphony-completed-runs-#{System.unique_integer([:positive])}.json")
    Application.put_env(:symphony_elixir, :completed_runs_file, path)

    on_exit(fn ->
      if is_nil(previous_path) do
        Application.delete_env(:symphony_elixir, :completed_runs_file)
      else
        Application.put_env(:symphony_elixir, :completed_runs_file, previous_path)
      end

      File.rm(path)
    end)

    %{path: path}
  end

  test "persists a bounded newest-first history", %{path: path} do
    assert CompletedRunStore.load(2) == []

    records = [
      completed_record("GH-3", ["done three"]),
      completed_record("GH-2", ["done two"]),
      completed_record("GH-1", ["done one"])
    ]

    assert :ok = CompletedRunStore.persist(records, 2)
    assert File.exists?(path)

    assert [
             %{identifier: "GH-3", agent_messages: ["done three"]},
             %{identifier: "GH-2", agent_messages: ["done two"]}
           ] = CompletedRunStore.load(2)

    assert {:ok, %{mode: mode}} = File.stat(path)
    assert Bitwise.band(mode, 0o777) == 0o600
  end

  test "returns an empty history for invalid data", %{path: path} do
    File.write!(path, "not-json")
    assert CompletedRunStore.load() == []

    File.write!(path, "{}")
    assert CompletedRunStore.load() == []
  end

  test "rejects malformed records and bounds retained messages", %{path: path} do
    oversized_message = String.duplicate("é", 20_000)

    File.write!(
      path,
      Jason.encode!([
        "not-a-record",
        %{
          "issue_id" => "issue-minimal",
          "identifier" => "GH-MINIMAL",
          "tokens" => "invalid",
          "agent_messages" => "invalid"
        },
        completed_record("GH-VALID", Enum.map(1..25, &"message #{&1}"))
        |> Map.put(:worker_host, 42)
        |> put_in([:agent_messages, Access.at(24)], oversized_message)
        |> put_in([:tokens, :cached_input_tokens], 10_000),
        completed_record("GH-BAD-MESSAGES", ["done"])
        |> Map.put(:agent_messages, "not-a-list"),
        completed_record("GH-BAD-TOKENS", ["done"])
        |> put_in([:tokens, :total_tokens], "many")
      ])
    )

    assert [
             %{
               identifier: "GH-VALID",
               tokens: %{
                 input_tokens: 100,
                 cached_input_tokens: 100,
                 output_tokens: 10,
                 total_tokens: 110
               },
               agent_messages: messages
             }
           ] = CompletedRunStore.load()

    assert length(messages) == 20
    assert hd(messages) == "message 6"
    assert byte_size(List.last(messages)) <= 20_000
    assert String.valid?(List.last(messages))
  end

  test "rejects negative numeric fields", %{path: path} do
    File.write!(
      path,
      Jason.encode!([
        completed_record("GH-BAD-RUNTIME", ["done"])
        |> Map.put(:runtime_seconds, -1),
        completed_record("GH-BAD-TURN", ["done"])
        |> Map.put(:turn_count, -1),
        completed_record("GH-BAD-INPUT", ["done"])
        |> put_in([:tokens, :input_tokens], -1)
      ])
    )

    assert CompletedRunStore.load() == []
  end

  test "can disable persistence entirely" do
    Application.put_env(:symphony_elixir, :completed_runs_file, false)

    assert CompletedRunStore.load() == []
    assert CompletedRunStore.persist([completed_record("GH-1", ["done"])]) == :ok
  end

  test "reports persistence failures and cleans temporary files", %{path: path} do
    File.mkdir_p!(path)

    assert {:error, _reason} =
             CompletedRunStore.persist([completed_record("GH-1", ["done"])])

    assert Path.wildcard("#{path}.tmp-*") == []
  end

  test "uses the configured log directory for the default history path", %{path: path} do
    previous_log_file = Application.get_env(:symphony_elixir, :log_file)
    Application.delete_env(:symphony_elixir, :completed_runs_file)
    Application.put_env(:symphony_elixir, :log_file, Path.join(Path.dirname(path), "runtime.log"))

    on_exit(fn ->
      if is_nil(previous_log_file) do
        Application.delete_env(:symphony_elixir, :log_file)
      else
        Application.put_env(:symphony_elixir, :log_file, previous_log_file)
      end

      File.rm(Path.join(Path.dirname(path), "completed-runs.json"))
    end)

    assert :ok = CompletedRunStore.persist([completed_record("GH-DEFAULT", ["done"])])
    assert [%{identifier: "GH-DEFAULT"}] = CompletedRunStore.load()
  end

  defp completed_record(identifier, messages) do
    %{
      issue_id: String.downcase(identifier),
      identifier: identifier,
      issue_url: "https://github.com/openai/symphony/issues/1",
      state: "Human Review",
      worker_host: nil,
      workspace_path: "/tmp/#{identifier}",
      session_id: "session-#{identifier}",
      started_at: "2026-07-24T20:00:00Z",
      completed_at: "2026-07-24T20:01:00Z",
      runtime_seconds: 60,
      turn_count: 1,
      tokens: %{
        input_tokens: 100,
        cached_input_tokens: 80,
        output_tokens: 10,
        total_tokens: 110
      },
      agent_messages: messages,
      last_event: "turn_completed",
      last_message: List.last(messages)
    }
  end
end
