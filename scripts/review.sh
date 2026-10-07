#!/bin/bash
# review.sh - code review via CodeRabbit, falls back to Ollama (cloud or local)
#
# Usage:  review.sh [base-branch]        (default: main)
#
# Environment variables:
#   OLLAMA_REVIEW_MODEL   model for the fallback (required, otherwise no fallback)
#   OLLAMA_URL            default: https://ollama.com (Ollama Cloud)
#   OLLAMA_API_KEY        required for Ollama Cloud, sent as Bearer token
#   OLLAMA_NUM_CTX        context window, default: 65536
#   REVIEW_MAX_BYTES      max diff size for the fallback, default: 150000
#
# Exit codes: 0 = review delivered, 1 = fallback not configured,
#             2 = CodeRabbit and Ollama both failed

set -u

BASE="${1:-main}"
OLLAMA_URL="${OLLAMA_URL:-https://ollama.com}"
OLLAMA_NUM_CTX="${OLLAMA_NUM_CTX:-65536}"
REVIEW_MAX_BYTES="${REVIEW_MAX_BYTES:-150000}"
LIMIT_REGEX='rate.?limit|limit reached|quota|not authenticated|unauthori[sz]ed|auth.*(required|failed)'

out=$(coderabbit review --agent --base "$BASE" 2>&1)
rc=$?

if [ "$rc" -eq 0 ]; then
  if [ -z "$out" ]; then
    echo "[review] source: CodeRabbit - no output (no findings)"
    exit 0
  fi
  if printf '%s' "$out" | grep -q '"type"' || ! printf '%s' "$out" | grep -qiE "$LIMIT_REGEX"; then
    echo "[review] source: CodeRabbit"
    printf '%s\n' "$out"
    exit 0
  fi
fi

echo "[review] CodeRabbit not usable (exit $rc), trying Ollama fallback" >&2
printf '%s\n' "$out" | head -n 5 >&2

if [ -z "${OLLAMA_REVIEW_MODEL:-}" ]; then
  echo "[review] OLLAMA_REVIEW_MODEL is not set, no fallback possible" >&2
  exit 1
fi

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "[review] not a git repository in the current directory" >&2
  exit 2
fi

merge_base=$(git merge-base "$BASE" HEAD 2>/dev/null) || {
  echo "[review] base branch '$BASE' not found" >&2
  exit 2
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

git diff "$merge_base" | head -c "$REVIEW_MAX_BYTES" > "$tmp/diff.txt"
if [ ! -s "$tmp/diff.txt" ]; then
  echo "[review] source: Ollama (${OLLAMA_REVIEW_MODEL}) - no changes against $BASE"
  exit 0
fi

{
  cat <<'EOF'
You are a strict, senior staff-level code reviewer. Review the git diff below as if you were blocking
a merge. Be skeptical by default: assume the author missed something until the diff proves otherwise.

Scope, in priority order:
1. Correctness bugs (logic errors, off-by-one, wrong operators, incorrect control flow)
2. Security issues (injection, unsafe deserialization, secrets, path traversal, auth/authz gaps)
3. Concurrency and race conditions (shared state, locking, async ordering)
4. Error handling (unchecked errors, swallowed exceptions, wrong exit codes, resource leaks)
5. API/behavior breaking changes (signature changes, removed fields, altered defaults)
6. Missing or weak tests for the changed behavior

Explicitly ignore: formatting, naming style, comment style, import order, and any nitpick that does not
change behavior or risk.

Rules:
- You only see the diff, not the full repository. Never assume context you cannot see; if a finding
  depends on code outside the diff, prefix the "comment" field with "Uncertain:" instead of asserting
  it as fact.
- Do not invent line numbers. If you cannot see an exact line, reference the nearest visible hunk header.
- Do not restate what the diff does. Only report actual problems.
- Every finding must include a concrete, actionable fix in "codegenInstructions" - not "consider
  reviewing this".
- Do not pad the review with praise, summaries, or filler text.

Output format: NDJSON, one compact JSON object per line, matching the CodeRabbit CLI agent-mode
schema exactly - no markdown, no prose, no code fences around the output.

Per finding, emit one line with exactly these fields:
{"type":"finding","severity":"<severity>","fileName":"<path>:<line-or-hunk>","codegenInstructions":"<concrete fix, as an instruction or code snippet>","suggestions":["<optional short fix snippet>"],"comment":"<one to three sentences, the concrete failure scenario>"}

"severity" must be exactly one of: critical, major, minor, trivial, info, none.
"suggestions" is an array, use [] when no short snippet applies.

Order findings most severe first. After the last finding (or if there are none), emit exactly one
final line: {"type":"complete","findings":<count>}

--- DIFF START ---
EOF
  cat "$tmp/diff.txt"
  printf '\n--- DIFF END ---\n'
} > "$tmp/prompt.txt"

jq -n \
  --arg model "$OLLAMA_REVIEW_MODEL" \
  --rawfile prompt "$tmp/prompt.txt" \
  --argjson ctx "$OLLAMA_NUM_CTX" \
  '{model: $model, prompt: $prompt, stream: false, options: {num_ctx: $ctx}}' > "$tmp/payload.json"

auth=()
if [ -n "${OLLAMA_API_KEY:-}" ]; then
  auth=(-H "Authorization: Bearer $OLLAMA_API_KEY")
fi

if ! response=$(curl -fsS "${OLLAMA_URL}/api/generate" \
      -H 'Content-Type: application/json' "${auth[@]}" \
      --data-binary @"$tmp/payload.json"); then
  echo "[review] Ollama request failed (${OLLAMA_URL})" >&2
  exit 2
fi

text=$(printf '%s' "$response" | jq -r '.response // empty')
if [ -z "$text" ]; then
  echo "[review] Ollama returned no response" >&2
  exit 2
fi

echo "[review] source: Ollama (${OLLAMA_REVIEW_MODEL}) - diff only, no repo context, treat as a second opinion"
printf '%s\n' "$text"
