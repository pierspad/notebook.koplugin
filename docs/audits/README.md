# Release verification records

- [1.7.0 — current stable verification](2026-10-05-release-1.7.0.md)
- [1.6.3 — continuous eraser regression and performance baseline](2026-10-02-release-1.6.3.md)

Keep concise release evidence here: scope, reproducible verification commands,
results and hardware limitations. Preserve a prior baseline when it explains a
current regression or performance decision. This directory is not a changelog
or a collection of temporary session notes.

Older investigations and raw benchmark outputs remain available in the
[v1.7.0 historical tree](https://github.com/pierspad/notebook.koplugin/tree/v1.7.0/docs/audits)
and Git history. Removing them from the current checkout does not erase history
or reduce the size of existing clones. Generate new raw outputs outside the
repository or in the ignored `docs/audits/results/` directory; retain selected
measurements with the code change only when they provide useful review evidence.
