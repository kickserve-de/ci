# Rich text for the merge comment (merge into main). Input: one entry. Args: $now.
include "lib";

"<body><strong>✅ Merged into \(.branch | html)</strong>\n\(.author | html) merged PR <a href=\"\(.link | @html)\">#\(.number) \(.subject | html)</a> from <code>\(.source | html)</code> into <code>\(.repo | html):\(.branch | html)</code>.\n<em>\($now | html)</em></body>"
