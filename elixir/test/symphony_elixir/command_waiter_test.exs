defmodule SymphonyElixir.CommandWaiterTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.CommandWaiter
  alias SymphonyElixir.WorkerToolchain

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "command-waiter-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)
    %{workspace: workspace}
  end

  test "worker toolchain exposes rg even when inherited PATH omits the Desktop bundle" do
    previous_path = System.get_env("PATH")
    System.put_env("PATH", "/usr/bin:/bin")

    try do
      {resolved, 0} =
        System.cmd("bash", ["-c", "command -v rg"],
          env: WorkerToolchain.command_env(),
          stderr_to_stdout: true
        )

      assert String.ends_with?(String.trim(resolved), "/rg")
    after
      System.put_env("PATH", previous_path)
    end
  end

  test "runs once without a PTY and returns a bounded passing summary", %{workspace: workspace} do
    command = """
    test ! -t 1
    test "$CI" = "1"
    test "$COLUMNS" = "160"
    printf 'stage output\\n'
    printf '12 tests, 0 failures\\n'
    printf 'Total errors: 0\\n'
    printf 'done (passed successfully)\\n'
    """

    assert {:ok, result} = CommandWaiter.run(workspace, command)
    assert result.status == :passed
    assert result.exit_code == 0
    assert result.command == command
    assert result.passed_stages == ["tests", "dialyzer", "quality gate"]
    assert result.failed_stages == []
    assert length(result.relevant_lines) <= 20
    assert File.read!(result.log_path) =~ "stage output\n12 tests, 0 failures\n"
  end

  test "streams full failure output to artifact but returns at most twenty relevant lines", %{
    workspace: workspace
  } do
    command = "for n in {1..40}; do echo \"ERROR failure-$n\"; done; exit 7"

    assert {:ok, result} = CommandWaiter.run(workspace, command)
    assert result.status == :failed
    assert result.exit_code == 7
    assert length(result.relevant_lines) == 20
    assert length(result.failed_stages) == 5

    full_log = File.read!(result.log_path)
    assert full_log =~ "ERROR failure-1"
    assert full_log =~ "ERROR failure-40"
  end

  test "terminates a timed-out command and reports the artifact", %{workspace: workspace} do
    assert {:ok, result} =
             CommandWaiter.run(workspace, "sleep 1", timeout_ms: 10, relevant_line_limit: 5)

    assert result.status == :timeout
    assert result.exit_code == nil
    assert File.exists?(result.log_path)
  end
end
