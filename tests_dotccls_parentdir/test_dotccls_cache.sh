#!/bin/bash
# test_dotccls_cache.sh — Test that findEntry caches .ccls.glnxa64 lookups.
#
# After the first file triggers a filesystem walk to find .ccls.glnxa64, the
# result is cached in discovered_dot_ccls. A second file in the same directory
# should use the cached args without walking the filesystem again. We verify
# this by checking that "Using nearest ccls file" appears only ONCE in the log
# even though two files are opened.
#
# Usage: ./test_dotccls_cache.sh [-verbose] [path-to-ccls-binary]

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
TMPDIR=$(mktemp -d /tmp/ccls_test_cache.XXXXXX)
if [ "$VERBOSE" = false ]; then
    trap "rm -rf $TMPDIR" EXIT
fi

mkdir -p "$TMPDIR/project/subdir"

# Empty compile_commands.json at root — forces findEntry fallback
echo "[]" > "$TMPDIR/project/compile_commands.json"

# .ccls.glnxa64 in subdirectory
cat > "$TMPDIR/project/subdir/.ccls.glnxa64" <<'EOF'
clang
-DTEST_MACRO=1
EOF

# Two test source files in the same directory
cat > "$TMPDIR/project/subdir/file1.cpp" <<'EOF'
#if !defined(TEST_MACRO)
#error "TEST_MACRO not defined"
#endif
int a = TEST_MACRO;
EOF

cat > "$TMPDIR/project/subdir/file2.cpp" <<'EOF'
#if !defined(TEST_MACRO)
#error "TEST_MACRO not defined"
#endif
int b = TEST_MACRO;
EOF

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
    echo "--- $TMPDIR/project/subdir/file1.cpp ---"
    cat "$TMPDIR/project/subdir/file1.cpp"
    echo ""
    echo "--- $TMPDIR/project/subdir/file2.cpp ---"
    cat "$TMPDIR/project/subdir/file2.cpp"
    echo ""
    echo "=== Running ccls ==="
    echo ""
fi

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

jsonrpc() {
    local content="$1"
    local len=${#content}
    printf "Content-Length: %d\r\n\r\n%s" "$len" "$content"
}

INIT="{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":$INIT_PARAMS}"
INITIALIZED='{"jsonrpc":"2.0","method":"initialized","params":{}}'

OPEN_FILE1=$(cat <<EOF
{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file://$TMPDIR/project/subdir/file1.cpp","languageId":"cpp","version":1,"text":"#if !defined(TEST_MACRO)\n#error \"TEST_MACRO not defined\"\n#endif\nint a = TEST_MACRO;\n"}}}
EOF
)

OPEN_FILE2=$(cat <<EOF
{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file://$TMPDIR/project/subdir/file2.cpp","languageId":"cpp","version":1,"text":"#if !defined(TEST_MACRO)\n#error \"TEST_MACRO not defined\"\n#endif\nint b = TEST_MACRO;\n"}}}
EOF
)

SHUTDOWN='{"jsonrpc":"2.0","id":2,"method":"shutdown","params":null}'
EXIT_MSG='{"jsonrpc":"2.0","method":"exit","params":null}'

LSP_LOG="$TMPDIR/ccls_log.txt"
LSP_OUT="$TMPDIR/ccls_stdout.txt"

{
    jsonrpc "$INIT"
    jsonrpc "$INITIALIZED"
    jsonrpc "$OPEN_FILE1"
    sleep 3
    jsonrpc "$OPEN_FILE2"
    sleep 3
    jsonrpc "$SHUTDOWN"
    sleep 1
    jsonrpc "$EXIT_MSG"
} | "$CCLS" --log-file="$LSP_LOG" --log-file-append -v=1 >"$LSP_OUT" 2>/dev/null || true

echo "=== ccls log (relevant lines) ==="
grep -E "Using nearest|parse|error:" "$LSP_LOG" 2>/dev/null || echo "(no relevant log lines)"
echo "=== end ccls log ==="
echo ""

PASS=true

# Check 1: Both files parsed without errors
if grep -q 'parse.*error:' "$LSP_LOG"; then
    PASS=false
    echo "CHECK 1: FAIL - parse errors detected"
    grep 'parse.*error:' "$LSP_LOG"
else
    echo "CHECK 1: PASS - both files parsed without errors"
fi

# Check 2: "Using nearest ccls file" appears exactly once (first file triggers
# filesystem walk, second file uses cached dot_ccls entry)
NEAREST_COUNT=$(grep -c "Using nearest ccls file" "$LSP_LOG" 2>/dev/null || echo "0")
if [ "$NEAREST_COUNT" -eq 1 ]; then
    echo "CHECK 2: PASS - 'Using nearest ccls file' logged once (second lookup used cache)"
elif [ "$NEAREST_COUNT" -eq 0 ]; then
    PASS=false
    echo "CHECK 2: FAIL - 'Using nearest ccls file' never logged (findEntry fallback not reached)"
else
    PASS=false
    echo "CHECK 2: FAIL - 'Using nearest ccls file' logged $NEAREST_COUNT times (caching not working)"
fi

# Check 3: Both files were actually parsed (confirm both went through indexing)
FILE1_PARSED=$(grep -c "parse.*file1.cpp" "$LSP_LOG" 2>/dev/null || echo "0")
FILE2_PARSED=$(grep -c "parse.*file2.cpp" "$LSP_LOG" 2>/dev/null || echo "0")
if [ "$FILE1_PARSED" -ge 1 ] && [ "$FILE2_PARSED" -ge 1 ]; then
    echo "CHECK 3: PASS - both file1.cpp and file2.cpp were parsed"
else
    PASS=false
    echo "CHECK 3: FAIL - file1 parsed=$FILE1_PARSED, file2 parsed=$FILE2_PARSED (expected both >= 1)"
fi

# Check 4: No LSP diagnostic errors for either file
if grep -q '"diagnostics":\[{' "$LSP_OUT"; then
    PASS=false
    echo "CHECK 4: FAIL - LSP reported diagnostic errors"
else
    echo "CHECK 4: PASS - no LSP diagnostic errors"
fi

echo ""
if [ "$PASS" = true ]; then
    echo "RESULT: PASS - dotCCLSFile caching verified"
else
    echo "RESULT: FAIL"
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
    echo "  file1 source:      $TMPDIR/project/subdir/file1.cpp"
    echo "  file2 source:      $TMPDIR/project/subdir/file2.cpp"
    echo "  ccls cache:        $TMPDIR/cache/"
    echo "  ccls log:          $TMPDIR/ccls_log.txt"
    echo "  ccls LSP output:   $TMPDIR/ccls_stdout.txt"
    echo ""
    echo "Directory NOT removed (use rm -rf $TMPDIR to clean up)"
fi

[ "$PASS" = true ] && exit 0 || exit 1
