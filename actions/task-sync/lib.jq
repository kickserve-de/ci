# Shared helpers for the task-sync jq filters (included via `jq -L <action dir>`).

def task_url_re: "https://(app\\.asana\\.com|work\\.kickserve\\.de|work\\.kcksrv\\.com)/\\S+";

# All task IDs in a text, in order of appearance. From a task URL only the last 16–17 digit number counts (Asana 16, Kickserve Work 17),
# otherwise /0/<project>/<task> would yield the project ID. Standalone IDs follow.
def tid:
  [ (match(task_url_re; "g").string | [match("[0-9]{16,17}"; "g").string] | last // empty),
    (gsub(task_url_re; "") | match("[0-9]{16,17}"; "g").string) ];

# First line without task links, IDs, ID fragments left over from GitHub truncating the title ("… 12098765…"),
# empty ()/[] and double spaces.
def clean:
  split("\n")[0]
  | gsub(task_url_re; "")
  | gsub("[0-9]{16,17}"; "")
  | gsub("\\s*[(\\[]?\\s*[0-9]{1,15}\\s*(…|\\.\\.\\.)\\s*$"; "")
  | gsub("\\s*(\\(\\s*\\)|\\[\\s*\\])"; "")
  | gsub("\\s{2,}"; " ")
  | gsub("^\\s+|\\s+$"; "");

# HTML escaping for Asana rich text. Asana shows &#39; (jq 1.6) literally instead of ', so quotes stay literal in
# element content; that is valid XML there and avoids version-dependent escaping. Not for attribute values.
def html: tostring | @html | gsub("&quot;"; "\"") | gsub("&#39;|&apos;"; "'");

# Remove duplicates, keep order.
def uniq_ordered: reduce .[] as $x ([]; if any(.[]; . == $x) then . else . + [$x] end);
