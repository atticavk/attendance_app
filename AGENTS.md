# Repository instructions

These instructions apply to the entire Flutter repository.

## Documentation is part of every change

Every code, configuration, dependency, asset, build, deployment, or behavior change must update documentation in the same commit.

- Update `docs/USER_GUIDE.md` for user-visible workflows, requirements, permissions, messages, or troubleshooting.
- Update `docs/DEVELOPER_GUIDE.md` for architecture, setup, configuration, APIs, dependencies, tests, builds, security, deployment, or operations.
- Update both for cross-cutting changes.
- Add a dated entry to each affected guide's `Documentation change log`.
- If there is genuinely no documentation impact, put `Documentation impact: none` and the reason in the commit or pull-request description.
- Never document passwords, tokens, signing secrets, private keys, or personal data.

Before completing a change, verify the guides match the implementation.
