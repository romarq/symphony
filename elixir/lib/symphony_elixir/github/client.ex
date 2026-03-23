defmodule SymphonyElixir.GitHub.Client do
  @moduledoc """
  GitHub Projects V2 GraphQL client for fetching project items, updating
  status columns, and managing issue comments.

  All user-supplied values are passed as GraphQL variables — never interpolated
  into query strings — to prevent injection.
  """

  require Logger
  alias SymphonyElixir.{Config, Linear.Issue}

  @graphql_endpoint "https://api.github.com/graphql"
  @rest_endpoint "https://api.github.com"
  @page_size 50
  @max_error_body_log_bytes 1_000

  # ---------------------------------------------------------------------------
  # GraphQL queries and mutations
  # ---------------------------------------------------------------------------

  # The user and org variants differ only in the root field (user vs organization).
  # Both return the same ProjectV2 shape.

  @project_items_query """
  query SymphonyGitHubProjectItems($owner: String!, $projectNumber: Int!, $statusField: String!, $first: Int!, $after: String) {
    user(login: $owner) {
      projectV2(number: $projectNumber) {
        id
        items(first: $first, after: $after) {
          nodes {
            id
            fieldValueByName(name: $statusField) {
              ... on ProjectV2ItemFieldSingleSelectValue { name optionId }
            }
            content {
              ... on Issue {
                id number title body state url
                assignees(first: 10) { nodes { login } }
                labels(first: 20) { nodes { name } }
                repository { nameWithOwner }
                createdAt updatedAt
              }
            }
          }
          pageInfo { hasNextPage endCursor }
        }
      }
    }
  }
  """

  @org_project_items_query """
  query SymphonyGitHubOrgProjectItems($owner: String!, $projectNumber: Int!, $statusField: String!, $first: Int!, $after: String) {
    organization(login: $owner) {
      projectV2(number: $projectNumber) {
        id
        items(first: $first, after: $after) {
          nodes {
            id
            fieldValueByName(name: $statusField) {
              ... on ProjectV2ItemFieldSingleSelectValue { name optionId }
            }
            content {
              ... on Issue {
                id number title body state url
                assignees(first: 10) { nodes { login } }
                labels(first: 20) { nodes { name } }
                repository { nameWithOwner }
                createdAt updatedAt
              }
            }
          }
          pageInfo { hasNextPage endCursor }
        }
      }
    }
  }
  """

  @project_fields_query """
  query SymphonyGitHubProjectFields($owner: String!, $projectNumber: Int!) {
    user(login: $owner) {
      projectV2(number: $projectNumber) {
        id
        field(name: "Status") {
          ... on ProjectV2SingleSelectField { id options { id name } }
        }
      }
    }
  }
  """

  @org_project_fields_query """
  query SymphonyGitHubOrgProjectFields($owner: String!, $projectNumber: Int!) {
    organization(login: $owner) {
      projectV2(number: $projectNumber) {
        id
        field(name: "Status") {
          ... on ProjectV2SingleSelectField { id options { id name } }
        }
      }
    }
  }
  """

  @update_status_mutation """
  mutation SymphonyUpdateProjectItemStatus($projectId: ID!, $itemId: ID!, $fieldId: ID!, $optionId: String!) {
    updateProjectV2ItemFieldValue(input: {
      projectId: $projectId, itemId: $itemId, fieldId: $fieldId,
      value: { singleSelectOptionId: $optionId }
    }) { projectV2Item { id } }
  }
  """

  @viewer_query """
  query SymphonyGitHubViewer { viewer { login } }
  """

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    tracker = Config.settings!().tracker

    with :ok <- validate_tracker(tracker),
         {:ok, assignee_filter} <- build_assignee_filter(tracker.assignee) do
      active_states = MapSet.new(tracker.active_states, &String.downcase/1)
      fetch_items_by_states(tracker, active_states, assignee_filter)
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states([]), do: {:ok, []}

  def fetch_issues_by_states(state_names) when is_list(state_names) do
    tracker = Config.settings!().tracker
    states = MapSet.new(state_names, &String.downcase/1)

    with {:ok, assignee_filter} <- build_assignee_filter(tracker.assignee) do
      fetch_items_by_states(tracker, states, assignee_filter)
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids([]), do: {:ok, []}

  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    ids = Enum.uniq(issue_ids)
    tracker = Config.settings!().tracker

    with {:ok, assignee_filter} <- build_assignee_filter(tracker.assignee),
         {:ok, all_items} <- fetch_all_items(tracker, assignee_filter) do
      index = Map.new(all_items, &{&1.id, &1})
      matching = Enum.flat_map(ids, fn id -> if issue = index[id], do: [issue], else: [] end)
      {:ok, matching}
    end
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_node_id, body) when is_binary(issue_node_id) and is_binary(body) do
    tracker = Config.settings!().tracker

    with {:ok, %{repo: repo, number: number}} <- resolve_issue_rest_info(tracker, issue_node_id),
         {:ok, _} <- post_rest_comment(tracker, repo, number, body) do
      :ok
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_node_id, state_name)
      when is_binary(issue_node_id) and is_binary(state_name) do
    tracker = Config.settings!().tracker

    with {:ok, raw_items} <- fetch_all_raw_items(tracker),
         {:ok, schema} <- fetch_project_schema(tracker),
         {:ok, item_id} <- find_project_item_id(raw_items, issue_node_id),
         {:ok, option_id} <- resolve_status_option_id(schema, state_name) do
      variables = %{
        projectId: schema.project_id,
        itemId: item_id,
        fieldId: schema.status_field_id,
        optionId: option_id
      }

      case do_graphql(@update_status_mutation, variables, tracker) do
        {:ok, %{"data" => %{"updateProjectV2ItemFieldValue" => %{"projectV2Item" => %{"id" => _}}}}} ->
          :ok

        {:ok, %{"errors" => errors}} ->
          {:error, {:github_graphql_errors, errors}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Private — pagination (shared by all fetch paths)
  # ---------------------------------------------------------------------------

  defp fetch_items_by_states(tracker, state_set, assignee_filter) do
    with {:ok, items} <- fetch_all_items(tracker, assignee_filter) do
      {:ok, Enum.filter(items, &state_active?(&1.state, state_set))}
    end
  end

  defp state_active?(nil, _state_set), do: false
  defp state_active?(state, state_set), do: MapSet.member?(state_set, String.downcase(state))

  defp fetch_all_items(tracker, assignee_filter) do
    with {:ok, raw_items} <- fetch_all_raw_items(tracker) do
      issues =
        raw_items
        |> Enum.map(&normalize_project_item(&1, tracker, assignee_filter))
        |> Enum.reject(&is_nil/1)

      {:ok, issues}
    end
  end

  defp fetch_all_raw_items(tracker), do: paginate_items(tracker, nil, [])

  defp paginate_items(tracker, cursor, acc) do
    variables =
      %{
        owner: tracker.project_owner,
        projectNumber: tracker.project_number,
        statusField: tracker.status_field_name || "Status",
        first: @page_size
      }
      |> maybe_put_cursor(cursor)

    case do_graphql(items_query(tracker), variables, tracker) do
      {:ok, %{"data" => data}} ->
        case extract_project(data) do
          %{"items" => %{"nodes" => nodes, "pageInfo" => page_info}} ->
            all = acc ++ nodes

            if page_info["hasNextPage"] == true and is_binary(page_info["endCursor"]) do
              paginate_items(tracker, page_info["endCursor"], all)
            else
              {:ok, all}
            end

          _ ->
            {:error, :project_not_found}
        end

      {:ok, %{"errors" => errors}} ->
        {:error, {:github_graphql_errors, errors}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Private — normalization
  # ---------------------------------------------------------------------------

  defp normalize_project_item(%{"content" => content, "fieldValueByName" => status_field}, tracker, assignee_filter)
       when is_map(content) do
    # Skip DraftIssues and PullRequests (they lack a number)
    if content["number"] == nil do
      nil
    else
      repo = get_in(content, ["repository", "nameWithOwner"]) || ""

      if tracker.repository != nil and repo != tracker.repository do
        nil
      else
        repo_short = repo |> String.split("/") |> List.last() || repo
        assignees = extract_assignee_logins(content)

        %Issue{
          id: content["id"],
          identifier: "#{repo_short}##{content["number"]}",
          title: content["title"],
          description: content["body"],
          priority: nil,
          state: if(is_map(status_field), do: status_field["name"]),
          branch_name: nil,
          url: content["url"],
          assignee_id: List.first(assignees),
          blocked_by: [],
          labels: extract_labels(content),
          assigned_to_worker: assigned_to_worker?(assignees, assignee_filter),
          created_at: parse_datetime(content["createdAt"]),
          updated_at: parse_datetime(content["updatedAt"])
        }
      end
    end
  end

  defp normalize_project_item(_item, _tracker, _assignee_filter), do: nil

  defp extract_assignee_logins(%{"assignees" => %{"nodes" => nodes}}) when is_list(nodes) do
    Enum.flat_map(nodes, fn
      %{"login" => login} when is_binary(login) -> [login]
      _ -> []
    end)
  end

  defp extract_assignee_logins(_), do: []

  defp extract_labels(%{"labels" => %{"nodes" => nodes}}) when is_list(nodes) do
    Enum.flat_map(nodes, fn
      %{"name" => name} when is_binary(name) -> [String.downcase(name)]
      _ -> []
    end)
  end

  defp extract_labels(_), do: []

  defp assigned_to_worker?(_assignees, nil), do: true

  defp assigned_to_worker?(assignees, %{match_values: match_values}) do
    Enum.any?(assignees, &MapSet.member?(match_values, String.downcase(&1)))
  end

  defp assigned_to_worker?(_assignees, _), do: false

  # ---------------------------------------------------------------------------
  # Private — assignee filtering
  # ---------------------------------------------------------------------------

  defp build_assignee_filter(nil), do: {:ok, nil}

  defp build_assignee_filter(assignee) when is_binary(assignee) do
    case String.trim(assignee) do
      "" -> {:ok, nil}
      "me" -> resolve_viewer_assignee_filter()
      login -> {:ok, %{match_values: MapSet.new([String.downcase(login)])}}
    end
  end

  defp resolve_viewer_assignee_filter do
    case do_graphql(@viewer_query) do
      {:ok, %{"data" => %{"viewer" => %{"login" => login}}}} when is_binary(login) ->
        {:ok, %{match_values: MapSet.new([String.downcase(login)])}}

      {:ok, _} ->
        {:error, :missing_github_viewer_identity}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Private — state update helpers
  # ---------------------------------------------------------------------------

  defp fetch_project_schema(tracker) do
    query = if org?(tracker), do: @org_project_fields_query, else: @project_fields_query
    variables = %{owner: tracker.project_owner, projectNumber: tracker.project_number}

    case do_graphql(query, variables, tracker) do
      {:ok, %{"data" => data}} ->
        case extract_project(data) do
          %{"id" => project_id, "field" => %{"id" => field_id, "options" => options}} ->
            {:ok, %{project_id: project_id, status_field_id: field_id, options: options}}

          _ ->
            {:error, :status_field_not_found}
        end

      {:ok, %{"errors" => errors}} ->
        {:error, {:github_graphql_errors, errors}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp find_project_item_id(raw_items, issue_node_id) do
    case Enum.find(raw_items, fn item -> get_in(item, ["content", "id"]) == issue_node_id end) do
      %{"id" => item_id} -> {:ok, item_id}
      nil -> {:error, {:issue_not_in_project, issue_node_id}}
    end
  end

  defp resolve_status_option_id(schema, state_name) do
    target = String.downcase(state_name)

    case Enum.find(schema.options, fn opt -> String.downcase(opt["name"]) == target end) do
      %{"id" => option_id} -> {:ok, option_id}
      nil -> {:error, {:status_option_not_found, state_name}}
    end
  end

  # ---------------------------------------------------------------------------
  # Private — REST comment creation
  # ---------------------------------------------------------------------------

  defp resolve_issue_rest_info(tracker, issue_node_id) do
    with {:ok, items} <- fetch_all_raw_items(tracker) do
      case Enum.find(items, fn item -> get_in(item, ["content", "id"]) == issue_node_id end) do
        %{"content" => %{"repository" => %{"nameWithOwner" => repo}, "number" => number}} ->
          {:ok, %{repo: repo, number: number}}

        _ ->
          {:error, {:issue_not_in_project, issue_node_id}}
      end
    end
  end

  defp post_rest_comment(tracker, repo, issue_number, body) do
    with {:ok, headers} <- rest_headers(tracker) do
      url = "#{@rest_endpoint}/repos/#{URI.encode(repo, &uri_path_char?/1)}/issues/#{issue_number}/comments"

      case Req.post(url, json: %{"body" => body}, headers: headers, connect_options: [timeout: 30_000]) do
        {:ok, %{status: status, body: resp_body}} when status in 200..299 ->
          {:ok, resp_body}

        {:ok, %{status: status, body: resp_body}} ->
          Logger.error("GitHub REST comment failed status=#{status} body=#{truncate_log(inspect(resp_body))}")
          {:error, {:github_rest_error, status}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Private — HTTP
  # ---------------------------------------------------------------------------

  defp do_graphql(query, variables \\ %{}, tracker \\ nil) do
    tracker = tracker || Config.settings!().tracker

    with {:ok, headers} <- graphql_headers(tracker) do
      payload = %{"query" => query, "variables" => variables}

      case Req.post(@graphql_endpoint, json: payload, headers: headers, connect_options: [timeout: 30_000]) do
        {:ok, %{status: 200, body: body}} ->
          {:ok, body}

        {:ok, %{status: status, body: body}} ->
          Logger.error("GitHub GraphQL failed status=#{status} body=#{truncate_log(inspect(body))}")
          {:error, {:github_graphql_http_error, status}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp graphql_headers(%{api_key: key}) when is_binary(key) and byte_size(key) > 0 do
    {:ok, %{"authorization" => "bearer #{key}", "content-type" => "application/json"}}
  end

  defp graphql_headers(_), do: {:error, :missing_github_token}

  defp rest_headers(%{api_key: key}) when is_binary(key) and byte_size(key) > 0 do
    {:ok,
     [
       {"authorization", "Bearer #{key}"},
       {"accept", "application/vnd.github+json"},
       {"x-github-api-version", "2022-11-28"}
     ]}
  end

  defp rest_headers(_), do: {:error, :missing_github_token}

  # ---------------------------------------------------------------------------
  # Private — helpers
  # ---------------------------------------------------------------------------

  defp validate_tracker(tracker) do
    cond do
      is_nil(tracker.api_key) -> {:error, :missing_github_token}
      is_nil(tracker.project_owner) -> {:error, :missing_project_owner}
      is_nil(tracker.project_number) -> {:error, :missing_project_number}
      true -> :ok
    end
  end

  defp items_query(tracker), do: if(org?(tracker), do: @org_project_items_query, else: @project_items_query)

  defp org?(%{endpoint: "org:" <> _}), do: true
  defp org?(_), do: false

  defp extract_project(%{"user" => %{"projectV2" => p}}) when is_map(p), do: p
  defp extract_project(%{"organization" => %{"projectV2" => p}}) when is_map(p), do: p
  defp extract_project(_), do: nil

  defp maybe_put_cursor(variables, nil), do: variables
  defp maybe_put_cursor(variables, cursor), do: Map.put(variables, :after, cursor)

  defp parse_datetime(nil), do: nil

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp truncate_log(str) when byte_size(str) > @max_error_body_log_bytes do
    String.slice(str, 0, @max_error_body_log_bytes) <> "..."
  end

  defp truncate_log(str), do: str

  defp uri_path_char?(char), do: char in ?a..?z or char in ?A..?Z or char in ?0..?9 or char in ~c"_.-~/"
end
