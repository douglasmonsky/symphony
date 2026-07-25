defmodule SymphonyElixir.GitHub.ResponseProjection do
  @moduledoc """
  Projects GitHub REST payloads into the small field set autonomous workers need.

  Host lifecycle code may use the full client response, but dynamic tool output
  is deliberately bounded before it enters model context.
  """

  @spec project(String.t(), String.t(), term()) :: term()
  def project(method, path, body) when is_binary(method) and is_binary(path) do
    cond do
      String.contains?(path, "/comments") -> project_comments(body)
      String.contains?(path, "/pulls") -> project_pulls(body)
      String.contains?(path, "/issues") -> project_issues(body)
      true -> project_generic(body)
    end
  end

  defp project_comments(comments) when is_list(comments), do: Enum.map(comments, &project_comment/1)
  defp project_comments(comment), do: project_comment(comment)

  defp project_comment(comment) when is_map(comment) do
    take_present(comment, ["id", "html_url"])
  end

  defp project_comment(other), do: project_generic(other)

  defp project_pulls(pulls) when is_list(pulls), do: Enum.map(pulls, &project_pull/1)
  defp project_pulls(pull), do: project_pull(pull)

  defp project_pull(pull) when is_map(pull) do
    take_present(pull, ["number", "state", "draft", "html_url"])
    |> maybe_put_ref("head", pull["head"])
    |> maybe_put_ref("base", pull["base"])
  end

  defp project_pull(other), do: project_generic(other)

  defp project_issues(issues) when is_list(issues), do: Enum.map(issues, &project_issue/1)
  defp project_issues(issue), do: project_issue(issue)

  defp project_issue(issue) when is_map(issue) do
    take_present(issue, ["number", "state", "html_url"])
    |> Map.put("labels", label_names(issue["labels"]))
  end

  defp project_issue(other), do: project_generic(other)

  defp project_generic(value) when is_list(value), do: Enum.map(value, &project_generic/1)

  defp project_generic(value) when is_map(value) do
    take_present(value, ["id", "number", "state", "draft", "html_url", "name", "ref"])
  end

  defp project_generic(value) when is_binary(value) or is_number(value) or is_boolean(value), do: value
  defp project_generic(_value), do: nil

  defp label_names(labels) when is_list(labels) do
    Enum.flat_map(labels, fn
      %{"name" => name} when is_binary(name) -> [name]
      name when is_binary(name) -> [name]
      _ -> []
    end)
  end

  defp label_names(_labels), do: []

  defp maybe_put_ref(projected, key, %{"ref" => ref}) when is_binary(ref) do
    Map.put(projected, key, %{"ref" => ref})
  end

  defp maybe_put_ref(projected, _key, _value), do: projected

  defp take_present(map, keys) do
    Enum.reduce(keys, %{}, fn key, acc ->
      case Map.fetch(map, key) do
        {:ok, nil} -> acc
        {:ok, value} -> Map.put(acc, key, value)
        :error -> acc
      end
    end)
  end
end
