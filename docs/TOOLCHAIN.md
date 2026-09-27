# Toolchain verification — both workers verified

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
- Initial attempt had no configured provider. After the user reported signing into the OpenCode console, the retry succeeded. `auth list` still displayed 0 credentials, so its output alone is not a reliable inference-availability check in this setup; no credential store was copied or exposed.
- `opencode models opencode-go --verbose` now exits 0 and lists **deepseek-v4.1-flash**, active, with High variant mapping to reasoningEffort=high.
- Delegation smoke test: **PASS**, exit 0, correct repository root/branch, documentation/config languages and top-level directories returned. SHA-256 comparison of all non-.git project files, including untracked files, reported **0 changes**.
- Exported session `ses_f1be5f966ffeoPIFvu1zfryF19` independently identifies provider **opencode-go**, model **deepseek-v4.1-flash**, variant **high**, and the expected project cwd/root. Raw evidence is in workspace work/toolchain, outside Git.
- The smoke test used process-scoped deny-by-default permissions with read/glob/grep/list and two exact read-only Git commands allowed. Two initial shell calls were correctly denied; the worker recovered using allowed tools and completed. No permission bypass was enabled.
- No subscription, payment, or credential was created on the user's behalf.

Supported non-interactive invocation, confirmed against installed CLI help:

```powershell
opencode run --dir "C:\Users\ginom\Documents\Codex\2026-09-27\files-pasted-by-the-user-you\outputs\BalatroAISparring" --model opencode-go/deepseek-v4.1-flash --variant high --format json "TASK"
```

Verification is complete for this worker. No `--auto` or permission bypass was needed. Milestone 0 independent source inspection has been delegated read-only to this exact model and High variant.

## Claude review worker

- Executable shim: `C:\Users\ginom\AppData\Roaming\npm\claude.ps1`.
- Installed version: **2.1.283**, updated by the user from 2.1.222.
- Exact model requested: `claude-opus-5-5`; explicit `--effort high`.
- Initial smoke test failed with an expired OAuth session. After the user updated the CLI, the retry **passed**, exit 0, is_error=false, terminal_reason=completed.
- Read-only smoke test invoked from the project directory using `Read,Glob,Grep` only, `--permission-mode dontAsk`, no session persistence and JSON output. It returned the correct repository path, directories and research status. No commands or file mutations were permitted.
- JSON modelUsage independently confirms canonicalModel **claude-opus-5-5**, firstParty provider, with actual token usage. Session: `9d60c0ab-aa0f-4cbc-ba0e-7e5d7610cc62`. High was set explicitly with `--effort high`.
- Installed version now exceeds the documented 2.1.280 minimum for Opus 5.5. No equivalent or fallback was substituted; the orchestrator did not change authentication.

Successful read-only invocation:

```powershell
claude -p --model claude-opus-5-5 --effort high --permission-mode dontAsk --tools 'Read,Glob,Grep' --allowedTools 'Read,Glob,Grep' --no-session-persistence --output-format json 'Read README.md and list the top-level directories. Do not modify files or run commands.'
```

## Workflow status

Astra can launch and capture both CLIs. **Both requested workers have returned verified authenticated responses using their exact models and High effort.** The required workflow is preserved: Astra -> DeepSeek -> Astra verification -> Claude review -> DeepSeek fixes -> Claude re-review -> Astra acceptance.

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
