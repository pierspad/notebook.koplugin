# Submitting Notebook to KOReader contrib

KOReader contrib's developer requirements are in its
[README](https://github.com/koreader/contrib#readme): working software, an upstream
Git submodule, and a README documenting functionality and device compatibility.
Notebook has a public upstream, MIT license, installable releases, README,
compatibility section and verification commands. Inclusion remains a maintainer
decision. Listing does not make the plugin part of official KOReader releases.

Use a separate clone; do not change the existing workspace's `contrib` checkout.
After Notebook v1.6.1 is published:

```bash
gh repo fork koreader/contrib --clone=false
# Run in a directory of your choice outside an existing repository.
git clone https://github.com/pierspad/contrib.git notebook-contrib-submission
cd notebook-contrib-submission
git remote add upstream https://github.com/koreader/contrib.git
git fetch upstream
git switch -c add-notebook upstream/main
git submodule add https://github.com/pierspad/notebook.koplugin.git notebook.koplugin
git -C notebook.koplugin checkout v1.6.1
git add .gitmodules notebook.koplugin
git diff --cached --submodule=short
git commit -m "Add Notebook handwriting plugin"
git push -u origin add-notebook
```

If `pierspad/contrib` already exists, use that fork instead of creating another.
The PR should target `koreader/contrib`, base `main`, compare
`pierspad: add-notebook`, and contain only `.gitmodules` plus the submodule pointer.
A submodule records a commit, not an automatically advancing release. Later
pointer updates require another contribution to contrib.

Suggested title: **Add Notebook handwriting plugin**

Suggested body:

> Adds Notebook as an upstream submodule pinned to the tested v1.6.1 release.
>
> Notebook provides stylus handwriting, pen/highlighter tools, whole-stroke and
> area erasing, lasso, editable text, multipage notebooks, PDF backgrounds and
> PDF/SVG/Xournal++ export. Kindle Scribe is the primary hardware target;
> compatibility and test scope are documented in the upstream README.
>
> Upstream: https://github.com/pierspad/notebook.koplugin
>
> Installation: use the upstream release ZIP. The source repository keeps the
> plugin in `lua/`; the submodule checkout itself is not an installable plugin
> directory. Please let me know if a different source layout is needed for
> contrib tooling.
>
> Validation: `make ci` and native KOReader offscreen checks.

Open the PR through GitHub's **Compare & pull request** after pushing the branch.
Respond to review requests. After merging, link the accepted PR in
[Notebook issue #1](https://github.com/pierspad/notebook.koplugin/issues/1) and
close that issue. Do not close it merely because a submission exists.
