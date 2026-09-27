# Toolchain verification — authentication pending

Verified on 2026-09-27. This records actual results; installed software and published model availability are not proof that authenticated inference works.

## Codex orchestrator

- Executable: `C:\Users\ginom\AppData\Local\OpenAI\Codex\bin\faa963e871dd422c\codex.exe`
- CLI: `0.158.0-alpha.2.1`.
- Current chat turn metadata: model `gpt-6-astra`, effort `medium`; also matches local configuration.
- Role: architecture, delegation, integration, independent verification, acceptance and Git history.

## OpenCode implementation worker

- Installed official standalone Windows x64 release **1.18.32**.
- Executable: `C:\Users\ginom\AppData\Local\Programs\OpenCodeCLI\opencode.exe`.
- Download SHA-256: `1483c72d5adced825590a0ecf8cc18b3e87e535960a125dbf539d33bce135d0f`, verified against official GitHub release asset digest before extraction.
- Added executable directory to **user-scope PATH** without replacing existing entries. A new PowerShell process using current machine/user PATH resolved `opencode` and returned version 1.18.32. Already-open applications may retain their old PATH; orchestration can use the absolute executable path.
- Official docs recommend WSL for best Windows experience but also support native binary releases and npm. Native standalone release selected to honor the requested preference and avoid adding a Linux environment.
- Provider: **OpenCode Go**, not the generic DeepSeek provider.
- Exact target: **DeepSeek V4.1 Flash**, `opencode-go/deepseek-v4.1-flash`.
- Public models.dev catalog confirms this provider/model and reasoning efforts `low`, `high`, `max`. The pinned OpenCode provider-transform source also supports High. Use `--variant high` as requested; stronger Max is not substituted.
- Project opencode.json pins the exact model and disables sharing. No credentials are stored in this repository.
- `opencode auth list`: **0 credentials**. No existing OpenCode/DeepSeek credential environment variables were found by name. Secrets were not printed.
- `opencode models opencode-go --refresh --verbose`: refreshed cache, then exited 1 with `Provider not found: opencode-go`. The public catalog independently contains it; authenticated provider availability remains unverified.
- Delegation smoke test: **not run**, awaiting the user-owned authentication step.

Manual next step, in a fresh PowerShell window:

```powershell
opencode auth login --provider opencode-go
```

Complete provider connection locally. Obtain any necessary Go subscription/key directly through OpenCode; do not paste keys into chat. No subscription, payment, or credential was created on the user's behalf.

Supported non-interactive invocation, confirmed against installed CLI help:

```powershell
opencode run --dir "C:\Users\ginom\Documents\Codex\2026-09-27\files-pasted-by-the-user-you\outputs\BalatroAISparring" --model opencode-go/deepseek-v4.1-flash --variant high --format json "TASK"
```

After authentication: rerun the provider model list, run the requested read-only repository inspection under restrictive permissions, capture JSON output/model identity and exit status, and compare tracked plus untracked file hashes before/after. Only then mark delegation verified. No `--auto` or permission bypass is needed for verification.

## Claude review worker

- Executable shim: `C:\Users\ginom\AppData\Roaming\npm\claude.ps1`.
- Installed version: **2.1.222**.
- Exact model requested: `claude-opus-5-5`; explicit `--effort high`.
- `claude auth status` reported a saved first-party Claude login. Actual inference failed: **OAuth session expired and could not be refreshed**. A saved login is not usable authentication.
- Read-only smoke test invoked from the project directory using `Read,Glob,Grep` only, `--permission-mode dontAsk`, no session persistence and JSON output. Exit code **1**, API duration 0, no model usage, no repository changes. It did not reach Opus inference.
- Current official Claude Code documentation states Opus 5.5 requires **2.1.280 or newer**, above the installed version. The exact public model name exists; no equivalent or fallback has been substituted.
- Claude authentication was not changed. To finish verification later, the client needs a supported version and the user must refresh the expired login; then rerun the exact-model smoke test. Neither review availability nor acceptance is claimed.

Attempted read-only invocation:

```powershell
claude -p --model claude-opus-5-5 --effort high --permission-mode dontAsk --tools 'Read,Glob,Grep' --allowedTools 'Read,Glob,Grep' --no-session-persistence --output-format json 'Read README.md and list the top-level directories. Do not modify files or run commands.'
```

## Workflow status

Astra can launch and capture both CLIs. **Neither external worker has yet produced a verified authenticated response.** The required workflow is preserved: Astra -> DeepSeek -> Astra verification -> Claude review -> DeepSeek fixes -> Claude re-review -> Astra acceptance.

Milestone 0 notes are committed. No mod feature implementation, live installation, automated match, benchmark, or V1 acceptance is claimed. Balatro was running during research, and the installation/Mods/saves were left unchanged.

## Sources

- Installation: https://opencode.ai/docs/#windows
- Exact release: https://github.com/anomalyco/opencode/releases/tag/v1.18.32
- CLI: https://opencode.ai/docs/cli/
- Go catalog and connection flow: https://opencode.ai/docs/go/
- Public model metadata: https://models.dev/api.json (provider opencode-go, model deepseek-v4.1-flash)
- Effort implementation: https://github.com/anomalyco/opencode/blob/v1.18.32/packages/opencode/src/provider/transform.ts
- Claude exact model/minimum version/effort: https://code.claude.com/docs/en/model-config
- Astra model: https://developers.openai.com/api/docs/models/gpt-6-astra
