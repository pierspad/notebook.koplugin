# Contributing

Search existing issues before opening a new one. For major changes, discuss the scope in an issue first.

## Issues

Use the bug report or feature request template. Include exact versions, reproduction steps, expected and actual behavior. Use small sample files when relevant; remove personal content and credentials from attachments.

## Pull requests

Keep changes focused. Explain the problem and resulting behavior, link related issues, and report the checks you ran and their results. Add regression coverage for behavior changes and update affected documentation. For interface changes, include a screenshot and update translations where needed.

## Development

From the repository root:

```sh
make verify
make check-package
```

For interface or translated layout changes, also run `make test-native-features` with a compiled KOReader runtime. See the [technical reference](docs/README.md), [translation guide](lua/locale/README.md) and [KOReader contribution workflow](docs/CONTRIB.md).
