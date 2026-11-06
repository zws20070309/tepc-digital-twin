# Contributing

Thanks for taking the time to contribute. This repository has an unusually strict
internal contract, so please read this page before opening a pull request.

## License of your contribution

This project is licensed under the **PolyForm Noncommercial License 1.0.0** (see `LICENSE`):
noncommercial use only, no commercial use. By opening a pull request you agree that your
contribution is licensed under the same terms. If you need a different arrangement (for example
a commercial licence for your own fork), say so in the pull request before we merge anything.

## Ground rules

1. **Counts are generated, never hand-edited.**
   `README.md`, `docs/quickstart.md` and `docs/VV_plan.md` quote test counts, gate
   counts, HDF5 dataset counts and anchor row counts. Those numbers are produced by
   `tools/genCounts.m` and checked against the documents by `tests/unit/test_doc_counts.m`.
   If your change alters any of them, regenerate instead of retyping:

   ```matlab
   cd <repo>/tests
   matlab -batch "addpath ../src; addpath ../app; addpath ../tools; genCounts"
   ```

2. **New claims need evidence in the register.**
   Anything the project asserts about itself lives in `config/capability_register.json`
   with a status (`DONE` / `PARTIAL` / `BLOCKED` / `EXCLUDED`), a gate layer and a
   reason. `docs/positioning.md` is generated from that file — do not edit it by hand.
   `tests/unit/test_positioning_claims.m` cross-checks that the two agree.

3. **Some sentences are banned on purpose.**
   `config/banned_claims.json` lists wording that the current evidence base cannot
   support, together with the reason and a replacement phrase. `test_report_semantics`
   scans `README.md`, `docs/*.md`, `app/`, `src/+tepc/+report/` and the artifacts of
   the newest run. If a sentence trips the scan, do not remove the scan — change the
   claim or add the evidence.

4. **Failures must be loud.**
   This codebase prefers an explicit error or a named gate over a silently plausible
   number. When you extend a chain, add the closure that proves it (energy bookkeeping,
   weight bookkeeping, seed identity, schema round-trip) rather than a tolerance that
   happens to pass.

5. **Determinism is a feature.**
   Anything that consumes randomness takes an explicit stream. Same seed must mean
   bit-identical output; if a change breaks bit-reproducibility, say so in the PR and
   document which quantity stopped being reproducible and why.

## Workflow

```matlab
% 1. run the suite before and after your change
cd tests; runAllTests('Quick',true)

% 2. if you touched the GUI or the report pipeline
cd tests_ui; runUiTests
```

* Keep pull requests focused. This repository has a long history of "one defect, one
  test that would have caught it" — please keep that shape.
* Explain *what would have failed* before your fix, and *which test now fails* if the
  fix is reverted.
* Markdown and MATLAB sources are UTF-8 without BOM and use LF line endings.

## Continuous integration

The authoritative gate is the MATLAB suite:

```bash
cd tests && matlab -batch "runAllTests"
```

GitHub-hosted runners have no MATLAB licence, so CI can only enforce the licence-free subset.
`tools/check_repository.py` covers that subset (JSON validity, UTF-8 without BOM, LF endings, the
banned-claim lexicon, relative README links) and needs nothing beyond Python 3.8+:

```bash
python tools/check_repository.py
```

To wire it into GitHub Actions, add this file as `.github/workflows/repo-checks.yml`
(it is not committed by default, because creating workflow files requires a token with the
`workflow` scope):

```yaml
name: repository checks
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
  workflow_dispatch:
permissions:
  contents: read
jobs:
  hygiene:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: "3.12"
      - run: python tools/check_repository.py
```

If you do have a MATLAB licence on a self-hosted runner, run the real suite instead and treat the
Python check as a fast pre-filter.

## Reporting bugs

Include the MATLAB release, the OS, the exact command, the run directory
(`runs/<run>/`) and the contents of `results/gates.json` for the failing run. The
gate file names the failing item and carries a recomputable value, which makes triage
much faster.

## Security

Please do not open a public issue for a security problem. See `SECURITY.md`.
