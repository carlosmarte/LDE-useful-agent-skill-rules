# LDE-useful-agent-skill-rules

General-use agent skills and rules. Each skill is a **single standalone `.md`
file at the repo root** — see [.CLAUDE.md](.CLAUDE.md) for the repo conventions.

## Skills

- [shell-source-encapsulation.md](shell-source-encapsulation.md) — write bash/zsh
  files that are safe to `source`: internals stay `local`, helpers are namespaced
  and retired, and only the one documented entry point goes global (with globals
  published solely on explicit opt-in).

## Tests

Test scripts live in `_tests_/<skill-name>/`. Run one suite:

```bash
_tests_/shell-source-encapsulation/run-tests.sh
```
