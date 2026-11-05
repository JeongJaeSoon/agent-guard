def valid_run:
  type == "object"
  and (.id | type == "number")
  and .id > 0
  and .id == (.id | floor)
  and all(.head_sha, .event, .head_branch, .path, .status; type == "string")
  and (.conclusion == null or (.conclusion | type == "string"));

if length != 1 or (.[0] | type) != "array" then
  error("expected one CI run response")
else
  .[0]
end
| if any(.[]; (.workflow_runs | type) != "array") then
  error("invalid CI run pages")
else
  [.[].workflow_runs[]]
end
| if all(.[]; valid_run) then . else error("invalid CI run metadata") end
| map(select(
    .head_sha == $sha
    and .path == ".github/workflows/ci.yml"
    and ((.event == $event and .head_branch == $branch)
         or .event == "workflow_dispatch")
  ))
| max_by(.id)
| . != null and .status == "completed" and .conclusion == "success"
