#!/bin/bash
# test_dotccls_path.sh — Self-contained test for the dotCCLSFile path separator fix.
#
# Bug: project.cc:findEntry() concatenated `cur + g_config->cache.dotCCLSFile`
#      without a "/" separator, producing e.g. "/tmp/dir.ccls.glnxa64" instead of
#      "/tmp/dir/.ccls.glnxa64". This meant ccls could never find custom-named
#      .ccls files via the findEntry fallback path (when the file is in a
#      subdirectory without a root-level .ccls file listing it).
#
# Test setup:
#   project/
#     compile_commands.json  (empty array — forces findEntry fallback)
#     subdir/
#       .ccls.glnxa64       (provides -DTEST_MACRO=1)
#       test.cpp            (uses TEST_MACRO)
#
# The .ccls.glnxa64 is in the subdirectory (not root), so ccls must use
# the findEntry() walk-up-the-tree fallback to discover it. This is the
# exact code path where the missing "/" bug lived.
#
# Usage: ./test_dotccls_path.sh [-verbose] [path-to-ccls-binary]

set -euo pipefail

VERBOSE=false
CCLS=""

for arg in "$@"; do
    case "$arg" in
        -verbose|--verbose) VERBOSE=true ;;
        *) CCLS="$arg" ;;
    esac
done

CCLS="${CCLS:-$(dirname "$0")/../build/ccls}"

if [ ! -x "$CCLS" ]; then
    echo "FAIL: ccls binary not found at $CCLS"
    exit 1
fi

# Create temp project structure
TMPDIR=$(mktemp -d /tmp/ccls_test_dotccls.XXXXXX)
if [ "$VERBOSE" = false ]; then
    trap "rm -rf $TMPDIR" EXIT
fi

mkdir -p "$TMPDIR/project/subdir"

# Empty compile_commands.json at root — forces ccls to use findEntry fallback
echo "[]" > "$TMPDIR/project/compile_commands.json"

# .ccls.glnxa64 in SUBDIRECTORY (not root) — findEntry must walk up and find it
cat > "$TMPDIR/project/subdir/.ccls.glnxa64" <<'EOF'
clang
-DTEST_MACRO=1
EOF

# Test source that uses TEST_MACRO
cat > "$TMPDIR/project/subdir/test.cpp" <<'EOF'
#if !defined(TEST_MACRO)
#error "TEST_MACRO not defined - ccls did not find .ccls.glnxa64"
#endif
int x = TEST_MACRO;
EOF

# Create cache directory
mkdir -p "$TMPDIR/cache"

if [ "$VERBOSE" = true ]; then
    echo "=== Test directory layout ==="
    echo "Root: $TMPDIR"
    echo ""
    find "$TMPDIR" -type f | sort | while read -r f; do
        echo "  $f"
    done
    echo ""
    echo "--- $TMPDIR/project/compile_commands.json ---"
    cat "$TMPDIR/project/compile_commands.json"
    echo ""
    echo "--- $TMPDIR/project/subdir/.ccls.glnxa64 ---"
    cat "$TMPDIR/project/subdir/.ccls.glnxa64"
    echo ""
    echo "--- $TMPDIR/project/subdir/test.cpp ---"
    cat "$TMPDIR/project/subdir/test.cpp"
    echo ""
    echo "=== Running ccls ==="
    echo ""
fi

# Build LSP initialize request with dotCCLSFile set
INIT_PARAMS=$(cat <<JSONEOF
{
  "processId": $$,
  "rootUri": "file://$TMPDIR/project",
  "capabilities": {},
  "initializationOptions": {
    "compilationDatabaseDirectory": "$TMPDIR/project",
    "cache": {
      "directory": "$TMPDIR/cache",
      "dotCCLSFile": ".ccls.glnxa64"
    },
    "index": {
      "threads": 1,
      "onChange": false
    }
  }
}
JSONEOF
)

# JSON-RPC helper: wrap content with Content-Length header
jsonrpc() {
    local content="$1"
    local len=${#content}
    printf "Content-Length: %d\r\n\r\n%s" "$len" "$content"
}

# Build the LSP messages
INIT=$(cat <<EOF
{"jsonrpc":"2.0","id":1,"method":"initialize","params":$INIT_PARAMS}
EOF
)

INITIALIZED=$(cat <<EOF
{"jsonrpc":"2.0","method":"initialized","params":{}}
EOF
)

OPEN_FILE=$(cat <<EOF
{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file://$TMPDIR/project/subdir/test.cpp","languageId":"cpp","version":1,"text":"#if !defined(TEST_MACRO)\n#error \"TEST_MACRO not defined - ccls did not find .ccls.glnxa64\"\n#endif\nint x = TEST_MACRO;\n"}}}
EOF
)

SHUTDOWN=$(cat <<EOF
{"jsonrpc":"2.0","id":2,"method":"shutdown","params":null}
EOF
)

EXIT_MSG=$(cat <<EOF
{"jsonrpc":"2.0","method":"exit","params":null}
EOF
)

# Send messages to ccls, capture stdout (LSP responses) and log file
LSP_LOG="$TMPDIR/ccls_log.txt"
LSP_OUT="$TMPDIR/ccls_stdout.txt"

{
    jsonrpc "$INIT"
    jsonrpc "$INITIALIZED"
    jsonrpc "$OPEN_FILE"
    sleep 5
    jsonrpc "$SHUTDOWN"
    sleep 1
    jsonrpc "$EXIT_MSG"
} | "$CCLS" --log-file="$LSP_LOG" --log-file-append -v=1 >"$LSP_OUT" 2>/dev/null || true

# Check results
echo "=== ccls log (relevant lines) ==="
grep -E "ccls\.glnxa64|parse|error:|Using nearest|findEntry" "$LSP_LOG" 2>/dev/null || echo "(no relevant log lines)"
echo "=== end ccls log ==="
echo ""

PASS=true

# Check 1: Did ccls find and use the .ccls.glnxa64 file via findEntry?
if grep -q "Using nearest ccls file.*\.ccls\.glnxa64" "$LSP_LOG"; then
    echo "CHECK 1: PASS - ccls found .ccls.glnxa64 via findEntry fallback"
else
    PASS=false
    echo "CHECK 1: FAIL - ccls did NOT find .ccls.glnxa64 via findEntry"
    echo "         (missing '/' in path concatenation at project.cc:findEntry)"
fi

# Check 2: No parse errors
if grep -q 'parse.*error:' "$LSP_LOG"; then
    PASS=false
    echo "CHECK 2: FAIL - ccls reported parse errors"
    grep 'parse.*error:' "$LSP_LOG"
else
    echo "CHECK 2: PASS - no parse errors"
fi

# Check 3: LSP diagnostics should be empty
if grep -q '"diagnostics":\[\]' "$LSP_OUT"; then
    echo "CHECK 3: PASS - LSP diagnostics empty"
elif grep -q '"diagnostics":\[{' "$LSP_OUT"; then
    PASS=false
    echo "CHECK 3: FAIL - LSP reported diagnostic errors"
else
    echo "CHECK 3: PASS - no diagnostic errors in LSP output"
fi

echo ""
if [ "$PASS" = true ]; then
    echo "RESULT: PASS - dotCCLSFile path separator fix verified"
else
    echo "RESULT: FAIL - dotCCLSFile path concatenation bug present"
    echo ""
    echo "Full ccls log:"
    cat "$LSP_LOG"
fi

if [ "$VERBOSE" = true ]; then
    echo ""
    echo "=== Verbose: test artifacts preserved ==="
    echo "Test directory: $TMPDIR"
    echo "  project root:      $TMPDIR/project/"
    echo "  compile_commands:   $TMPDIR/project/compile_commands.json"
    echo "  .ccls.glnxa64:     $TMPDIR/project/subdir/.ccls.glnxa64"
    echo "  test source:       $TMPDIR/project/subdir/test.cpp"
    echo "  ccls cache:        $TMPDIR/cache/"
    echo "  ccls log:          $TMPDIR/ccls_log.txt"
    echo "  ccls LSP output:   $TMPDIR/ccls_stdout.txt"
    echo ""
    echo "Directory NOT removed (use rm -rf $TMPDIR to clean up)"
fi

[ "$PASS" = true ] && exit 0 || exit 1
