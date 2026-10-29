# Task IDs of a version. Input: the commit messages (array, oldest first). Like task-sync for pushes,
# a commit counts for the first ID in its message (merge commits name the branch, which carries it).
# Output: each ID once, in order of first appearance.
include "lib";

[.[] | tid | first // empty] | uniq_ordered | .[]
