# Notebook release and interaction polish

Goal: deliver the user-requested refinements through tested commits on dev and a semantic-release stable ZIP on main.
Architecture: retain vector storage and KOReader plugin API. Keep hot input work bounded; use existing scalar pressure and color fields. Release preparation injects the computed version before packaging.

- [ ] Release: compare Vesta; configure semantic-release main/dev, exact package versions and GitHub assets; validate prerelease before stable promotion.
- [ ] Input: trace native pressure and selection lifecycle; regression tests for observed failures, then fix without weakening palm protection.
- [ ] Rendering: lightweight eraser outline, uniform live highlighter tone, optional held-curve smoothing with conservative recognizer fallback.
- [ ] UI: distinguish brush and line-effect sections/icons; put settings at far right with clock beside page-forward.
- [ ] Export: crop toolbar from page using persisted content origin; reduce per-pixel Lua work, test real PDF output and sharing.
- [ ] Gallery: bounded drag-to-select behavior, convenient folder-name presets and faster bulk deletion where measurable.
- [ ] Integrate: focused tests and full make ci before each independent commit/push; Kindle native tests and install; promote dev to main and verify uploaded release artifact.

Constraints: retain existing uncommitted tuning plan edit; no notebook format migration; preserve undo and final drag position; no physical-input claims without physical measurements. Agents edit only assigned files, never commit or push; coordinator handles all Git operations.
