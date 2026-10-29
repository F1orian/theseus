# Open WebUI fixtures

Scrubbed responses replayed by unit tests through `StubTransport` (target `Fixtures`).

- `open-webui-<version>/*.json` are **recorded** from the test Server by `scripts/record-fixtures`.
  Tokens, emails, names, user/chat ids, chat titles and the Server host are replaced with placeholders.
  Re-record after a Server upgrade; the directory name carries the Server version.
- `open-webui-<version>/synthetic/*.json` are **hand-written** from the server source
  (`backend/open_webui/models/auths.py` `SigninResult`, FastAPI error bodies) for shapes the test Server
  cannot produce safely (MFA challenges, pending approval, sign-in errors). The recorder never touches them.

Never commit an unscrubbed response. The recorder aborts if it finds the `.env` email, token, user id or host.
Both recorders then run `scripts/fixtures/scrub_ids.py`, which swaps every other server- or provider-generated id
(messages, files, tasks, `msg_…`, `toolu_…`) for a placeholder; `--check` fails if one is left. Usage counts,
the default model and terminal servers are replaced with made-up values too.
