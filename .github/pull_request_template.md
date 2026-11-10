## Summary

<!-- One or two lines: what changes and why. -->

## Checklist

- [ ] `scripts/lint-shell.sh` run locally, exits 0
- [ ] All Bazel gates green (`bazel run //:check`)
- [ ] DCO sign-off present on every commit — added by the `prepare-commit-msg` hook, never typed by hand
- [ ] `typescript/pnpm-lock.yaml` and `python/uv.lock` regenerated in this PR if any dependency changed
- [ ] Linked the issue this closes (`Fixes #N`), if any
- [ ] Screenshots or notes attached for any UI change
