## Code review

Run `review [base-branch]` (default: main) instead of calling `coderabbit` directly.
It uses CodeRabbit and falls back to an Ollama model when CodeRabbit is unavailable.
Ollama output only sees the diff: treat it as a second opinion and verify every point
against the code before changing anything. Run it before opening a PR.
