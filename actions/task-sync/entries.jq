# Builds a list of entries from the GitHub event, one entry per commit or PR.
# Input: event payload. Args: $event, $ref, $repo, $main, $commit_msgs (messages of the PR commits, PRs only).
# Task ID for commits: message → branch. For PRs: title → head branch → PR commits.
include "lib";

if $event == "pull_request" then
  .pull_request as $pr
  | (if .action == "opened" then "PR"
     elif .action == "closed" and $pr.merged then
       (if $pr.base.ref == $main then "MERGED_MAIN" else "MERGED" end)
     else null end) as $type
  | if $type == null then [] else
      ($pr.title | tid | first) as $from_title
      | ($pr.head.ref | tid | last) as $from_branch
      | ([$commit_msgs[] | tid[]] | uniq_ordered) as $from_commits
      | [{
          task:        ($from_title // $from_branch // $from_commits[0]),
          task_source: (if $from_title then "title" elif $from_branch then "branch"
                        elif $from_commits[0] then "commits" else null end),
          commit_tasks: $from_commits,
          type:        $type,
          author:      (if $type == "PR" then $pr.user.login else ($pr.merged_by.login // $pr.user.login) end),
          repo:        $repo,
          branch:      $pr.base.ref,
          source:      $pr.head.ref,
          link:        $pr.html_url,
          number:      $pr.number,
          subject:     ($pr.title | clean)
        }] end
else
  [ (.commits // [])[]
    | select(.distinct)
    | select(.committer.username != "web-flow")   # merges/squashes via GitHub are handled by the PR event
    | (.message | tid | first) as $from_message
    | {
        task:        ($from_message // ($ref | tid | last)),
        task_source: (if $from_message then "message" else "branch" end),
        type:        "PUSH",
        author:      (.author.username // .author.name),
        repo:        $repo,
        branch:      $ref,
        link:        .url,
        sha:         .id[0:7],
        subject:     (.message | clean)
      } ]
end
| map(select(.task != null))
