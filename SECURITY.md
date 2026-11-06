# Security policy

## Scope

This repository is a numerical simulation and desktop UI. It does not open network
sockets, does not execute downloaded code and does not require credentials. The
practical risk surface is therefore small, but two areas are worth reporting:

* **File writes.** Runs create `runs/<timestamp>-<id>/` trees. The base directory can be
  redirected with the `TEPC_RUNS_DIR` environment variable. A path-traversal or
  overwrite issue in run-directory layout is in scope.
* **Untrusted input files.** Configuration JSON and the 3-D device manifest are parsed
  and validated. A crafted file that causes code execution, or that bypasses a
  validation guard, is in scope.

## Reporting

Please report suspected issues privately through the repository's GitHub Security
advisory tab (Security → Report a vulnerability) rather than in a public issue.
Include the MATLAB release, the version or commit, and a minimal reproducing input.

## Not a safety claim

Nothing in this repository is a radiation-protection instrument, a certified dosimeter
or a clinical tool. See the "Honest limitations" section of `README.md` and the
generated `docs/positioning.md` for what the model may and may not be used for.
