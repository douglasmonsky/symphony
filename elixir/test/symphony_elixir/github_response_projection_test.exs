defmodule SymphonyElixir.GitHub.ResponseProjectionTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.GitHub.ResponseProjection

  test "projects issue identity and label names from map and string labels" do
    body = [
      %{
        "number" => 7,
        "state" => "open",
        "html_url" => "https://github.test/issues/7",
        "title" => "discarded",
        "labels" => [%{"name" => "agent-ready"}, "documentation", %{"color" => "fff"}]
      }
    ]

    assert ResponseProjection.project("GET", "/repos/acme/repo/issues", body) == [
             %{
               "number" => 7,
               "state" => "open",
               "html_url" => "https://github.test/issues/7",
               "labels" => ["agent-ready", "documentation"]
             }
           ]

    assert ResponseProjection.project("GET", "/repos/acme/repo/issues", "unexpected") ==
             "unexpected"

    assert ResponseProjection.project("GET", "/repos/acme/repo/issues/8", %{
             "number" => 8,
             "state" => nil,
             "labels" => nil
           }) == %{"number" => 8, "labels" => []}
  end

  test "projects pull identity and head/base refs" do
    pull = %{
      "number" => 9,
      "state" => "open",
      "draft" => false,
      "html_url" => "https://github.test/pulls/9",
      "head" => %{"ref" => "feature", "sha" => "abc", "repo" => %{"full_name" => "discarded"}},
      "base" => %{"ref" => "main", "sha" => "def"},
      "user" => %{"login" => "discarded"}
    }

    assert ResponseProjection.project("GET", "/repos/acme/repo/pulls", pull) == %{
             "number" => 9,
             "state" => "open",
             "draft" => false,
             "html_url" => "https://github.test/pulls/9",
             "head" => %{"ref" => "feature"},
             "base" => %{"ref" => "main"}
           }

    assert ResponseProjection.project("GET", "/repos/acme/repo/pulls", "unexpected") ==
             "unexpected"

    assert ResponseProjection.project("GET", "/repos/acme/repo/pulls", %{
             "number" => 10,
             "head" => nil,
             "base" => %{}
           }) == %{"number" => 10}
  end

  test "projects comments to workpad identity only" do
    comments = [
      %{
        "id" => 41,
        "html_url" => "https://github.test/comment/41",
        "body" => "discarded",
        "user" => %{"login" => "discarded"},
        "reactions" => %{"total_count" => 5}
      },
      "unexpected"
    ]

    assert ResponseProjection.project("GET", "/repos/acme/repo/issues/7/comments", comments) == [
             %{"id" => 41, "html_url" => "https://github.test/comment/41"},
             "unexpected"
           ]
  end

  test "projects generic response maps and recursively projects lists" do
    generic = %{
      "id" => 12,
      "name" => "symphony",
      "status" => "discarded",
      "owner" => %{"login" => "discarded"}
    }

    assert ResponseProjection.project("POST", "/repos/acme/repo/labels", generic) == %{
             "id" => 12,
             "name" => "symphony"
           }

    assert ResponseProjection.project("POST", "/other", ["ok", 2, %{"id" => 4}]) == [
             "ok",
             2,
             %{"id" => 4}
           ]
  end
end
