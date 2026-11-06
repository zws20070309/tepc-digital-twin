# TEPC Digital Twin — Analytical Event / Electronics / Microdosimetry Baseline

**English** · [简体中文](README.md)

> **Delivery label: RESEARCH / DEMO.** This repository is an analytical surrogate model. It is
> **not** a Monte Carlo transport code, and it is **not** a validated reproduction of any real
> detector. No reference-field calibration data exists here, so absolute dose is blocked from
> publication by a built-in gate. Every claim this project makes is capped by
> [`docs/positioning.md`](docs/positioning.md), which is generated from
> [`config/capability_register.json`](config/capability_register.json).

---

## What this is

A pure-MATLAB digital twin of a **spherical tissue-equivalent proportional counter (TEPC)**, built
as a single reproducible chain from radiation source to microdosimetric spectrum:

```
config / source  →  geometry / field  →  transport adapter  →  event construction
      →  ionization / drift / avalanche  →  preamp / shaper / ADC  →  microdosimetry
      →  uncertainty & validation  →  GUI / HTML report
```

Every stage is deterministic given a seed, hash-stamped, and re-checkable from the files it wrote.
The transport stage is an **analytical / empirical adapter** — two-body neutron elastic kinematics,
Klein–Nishina Compton scattering, Bethe stopping power with effective charge and anchored
splicing — deliberately not a collision-by-collision Monte Carlo.

## What this is not

| Not claimed | Why not |
|---|---|
| Monte Carlo transport | The adapter uses closed-form tracks with a fixed substream; there is no collision-level stepping and no neutral-particle transport |
| Reproduction of any real device | Dimensions, materials and gas mixture are taken from design parameters and the literature; the model has never been compared against a physical detector |
| Validated absolute dose | There is no reference-field calibration data; `runGate` returns `NOT_EVALUATED` for that item and the release flag stays false |
| Precision neutron / gamma response | Elastic cross-section weights, gamma mass attenuation and the photoelectric branch are ASSUMED placeholder values, registered as such in every output file |

## At a glance

| | |
|---|---|
| Language | MATLAB (pure `.m`, no MEX, no Java, no compiled artifacts) |
| Releases | Built and verified on **R2025a**; requires **R2023b+** |
| Required toolboxes | Simulink (reference electronics model), Parallel Computing Toolbox (background GUI runs, process pool), PDE Toolbox (optional FEM field map) |
| Not required | Statistics Toolbox — LHS, Poisson, quantiles, bootstrap and `norminv` are implemented in-repo |
| Entry points | `tepc_quickstart`, `tepc_gui`, `tepc_3d_workbench` |
| Verification | See [Verification](#verification) |
| License | `LICENSE` file; third-party data terms in [Data provenance](#data-provenance-and-third-party-data) |

## Why it exists

Microdosimetry pipelines are usually validated end-to-end against a physical detector, which makes
them hard to extend without hardware in the loop. This project takes the opposite bet: build each
stage as a **checkable closure** — energy bookkeeping, weight bookkeeping, seed identity, schema
contracts, hash provenance — so that a change anywhere in the chain either reproduces bit-for-bit or
fails loudly at a named gate. The point is not to predict a detector. The point is to have a
research vehicle where every number that leaves the process can be traced back to the code, config
and random stream that produced it.

## Pipeline

```
┌──────────────┐   ┌───────────────┐   ┌──────────────────┐   ┌─────────────────┐
│ config v1    │──▶│ geometry      │──▶│ transport adapter│──▶│ event batch     │
│ (JSON+schema)│   │ chord / field │   │ analytic/empirical│  │ (SoA, 23 cols)  │
└──────────────┘   └───────────────┘   └──────────────────┘   └────────┬────────┘
                                                                       │
   ┌───────────────────────────────────────────────────────────────────▼──────┐
   │ detector: ion pairs → drift → avalanche (Polya) → Shockley-Ramo waveform │
   └────────────────────────────────────┬─────────────────────────────────────┘
                                        │
   ┌────────────────────────────────────▼─────────────────────────────────────┐
   │ electronics: CSA → PZ / CR-RC shaper → ADC (dual range, INL) → trigger   │
   └────────────────────────────────────┬─────────────────────────────────────┘
                                        │
   ┌────────────────────────────────────▼─────────────────────────────────────┐
   │ analysis: f(y) / d(y) → yF, yD → Q(y) → dose chains → instrument inversion│
   └────────────────────────────────────┬─────────────────────────────────────┘
                                        │
   ┌────────────────────────────────────▼─────────────────────────────────────┐
   │ validation: 16 red-line gates → release flag → report.html / summary.json │
   └──────────────────────────────────────────────────────────────────────────┘
```

## Quick start

Clone the repository and open MATLAB **with the repository root as the current folder**. Nothing
below hard-codes a path — each entry script resolves the root from its own location.

```matlab
tepc_quickstart      % build path → run a 10,000-event demo (fixed seed) → print the summary
```

That single call produces the full evidence set under `runs/<timestamp>-<id>/`:

```
runs/<run>/
├── events/events.h5        % fixed-schema event batch + root attributes
├── results/spectrum.csv    % 12-column weighted microdosimetric spectrum
├── results/summary.json    % yF / yD / Qbar / dose lines / flags / limits
├── results/gates.json      % 16 gates, each with a recomputable value
├── results/provenance.json % versions, seed, hashes, per-parameter status
├── results/report.html     % self-contained validation report
└── figures/diagnostic.png
```

Scripted use:

```matlab
project = tepc.Project.open("config/defaults/demo_only.json");
run     = project.execute('N', 1e5);
project.exportReport(run, fullfile(run.runDir.results, 'report.html'));
```

Graphical interface and 3-D audit workbench:

```matlab
tepc_gui                  % 9-tab application: run / pause / cancel, spectra, gates
app = tepc_gui(false);    % headless self-check (used by the test suite)
tepc_3d_workbench         % independent 3-D geometry workbench with clipping
```

> `tepc_gui` and `tepc_3d_workbench` must be invoked from the repository root: they build the
> `src/` + `app/` path themselves, and the default config path is relative.

## Repository layout

| Path | Contents |
|---|---|
| `src/+tepc/` | The whole physics and data layer, as a MATLAB package (16 sub-packages) |
| `app/` | GUI: `TEPCApp` (9 tabs), `AppController` state machine, `AppState`, `Theme`, components |
| `config/` | v1 config JSON + schema, capability register, banned-claim lexicon, reference data |
| `tests/` | Unit + integration suite with a build-failing exit code |
| `tests_ui/` | UI cases that drive a real `uifigure` and real callbacks |
| `tools/` | Count generator, evidence index, positioning generator, one-off probes |
| `workflows/` | `run_demo` — the demonstration entry point (not a test) |
| `docs/` | Requirements, V&V plan, uncertainty budget, positioning, constants, evidence logs |
| `geometry/` | 3-D device manifest and material table |
| `simulink/` | `TEPC_Electronics.slx` reference model (parameters injected from config) |
| `runs/` | Run artifacts, produced at execution time (git-ignored) |

## Verification

The suite is a **build gate**, not a report: any failed or incomplete case raises, so
`matlab -batch runAllTests` exits non-zero.

```matlab
cd tests; runAllTests                        % full suite, 617 cases
cd tests; runAllTests('Quick',true)          % skip the long GUI end-to-end case
cd tests; runAllTests('WriteLog',true)       % also write a UTF-8 case-level log
cd tests_ui; runUiTests                      % UI cases (2)
```

What the suite actually pins down, layer by layer:

* **Closures** — energy bookkeeping, weight bookkeeping, exact-moment identities for `f(y)`/`d(y)`,
  charge conservation, Ramo electron/ion share, and the HDF5 read-back recomputation.
* **Reproducibility** — same seed ⇒ bit-identical spectrum; `1000 + 1000` events ⇒ bit-identical to
  `2000`; checkpoint/restart is bit-exact and rejects a mismatched seed or config hash.
* **Distribution shape** — chord length is tested with KS *and* Anderson–Darling against the closed
  form, with the p-value calibrated by an on-the-fly Monte Carlo reference.
* **External anchors** — NIST PSTAR liquid-water proton range (88 points), two stopping-power
  anchors, and sha256 self-checks on the reference tables.
* **Cross-checks** — MATLAB vs Simulink over a 6-operating-point matrix, and a full-tree
  certification that per-file test counts on disk equal what the runner actually collects.
* **Governance** — every numeric claim quoted in `README.md`, `docs/quickstart.md` and
  `docs/VV_plan.md` is compared against values recomputed by `tools/genCounts.m`; a banned-claim
  lexicon is scanned across all deliverable text; capability status must agree between the register
  and `docs/positioning.md`.

Counts are always **generated**, never hand-copied:

```matlab
cd <repo>/tests; matlab -batch "addpath ../src; addpath ../app; addpath ../tools; genCounts"
```

## Honest limitations

These are load-bearing, not boilerplate. Read them before reusing any number this project emits.

1. **No Monte Carlo.** Transport is a closed-form adapter; any channel that would need collision-level
   physics is either absent or flagged ASSUMED.
2. **Dose chains are internally consistent, not externally validated.** The three dose chains
   (truth, instrument inversion, closed-form definition) are checked against each other; none is
   checked against a calibration field.
3. **Low-energy stopping power is an anchored splice.** Below 1 MeV the curve is stitched to anchors
   and carries a documented ±15 % (below 80 keV, ±30 %).
4. **The avalanche start radius is a constant.** All events share one ASSUMED radius, so ballistic
   deficit is a fixed mean absorbed by the charge-injection calibration. There is no genuine
   radial-position smearing, so the published resolution is not a detector resolution.
5. **The published spectrum is the instrument-inverted energy**, not the true deposit; the same
   event set's truth spectrum is published alongside for cross-checking.
6. **`field.mode="fem_map"` is not bit-reproducible.** Node counts, DOF and solution size agree run
   to run, but the solution vector's hash changes with thread reduction order (pairwise deltas
   ~4.4e-16). Cross-run hash promises cover analytical/closed-form quantities and counts only.
7. **The demo config is deliberately inconsistent** (1000 Pa ↔ 2 µm site). The inconsistency is
   detected and surfaced as a WARN / orange banner; the derived equivalent site is used for physics.
8. **Geant4 / FLUKA / MCNP adapters do not exist.** `TransportAdapter` is an extension interface.

## Data provenance and third-party data

Reference tables under `config/reference/` and `config/quality-factor/` are either extracted from
public authoritative sources or digitized from published figures. Each file carries its provenance
in a `#` header and is registered with a source, a grade (A/B/C) and a retrieval date in
[`docs/reference_register.csv`](docs/reference_register.csv). They are distributed here **only** as
numerical inputs to the verification gates.

| File | Origin | Grade |
|---|---|---|
| `stopping_anchors.csv` | NIST PSTAR / ESTAR | REFERENCE |
| `pstar_water_proton_range.csv` | NIST PSTAR, liquid water, 88 points, 10 keV–100 MeV | A |
| `icrp103_neutron_wR_branches.csv` | ICRP Publication 103, §B, eq. (2.8) | A |
| `icrp110_tissue_elemental_composition.csv` | ICRP Publication 110, Annex B, Tables B.1/B.2 | A |
| `icrp116_neutron_skin_lens_coefficients.csv` | ICRP Publication 116, Tables C.12/C.27/F.3 | A |
| `lhasa_neutron_spectrum*.csv` | Digitized from Peng et al., *High Power Laser and Particle Beams* 35:059001 (2023), doi:10.11884/HPLPB202335.220353 | digitized |
| `icrp60_let_on_y.csv` | ICRP Publication 60, Q(L) piecewise definition | A |

If you redistribute this repository, keep these attributions intact. Copyright in the underlying
publications remains with their respective owners; no source document is redistributed here.

## Documentation

| Document | Contents |
|---|---|
| [`docs/quickstart.md`](docs/quickstart.md) | Clean-session reproduction guide, including deliberate-failure demos |
| [`docs/requirements.md`](docs/requirements.md) | Requirements, scope and acceptance table |
| [`docs/VV_plan.md`](docs/VV_plan.md) | Verification plan with pre-registered tolerances |
| [`docs/uncertainty_budget.md`](docs/uncertainty_budget.md) | Uncertainty budget |
| [`docs/positioning.md`](docs/positioning.md) | Generated statement of what may and may not be claimed |
| [`docs/performance_tiers.md`](docs/performance_tiers.md) | Cost/fidelity axes and the measurements that rejected each one |
| [`docs/reference_register.csv`](docs/reference_register.csv) | Provenance and status of every constant |
| [`docs/constants.json`](docs/constants.json) | Versioned constants registry (single source of truth) |
| [`config/banned_claims.json`](config/banned_claims.json) | Claims that must not appear, with the reason and the replacement wording |

## Citation

If you use this code in academic work, cite it via the metadata in [`CITATION.cff`](CITATION.cff).

## License

See [`LICENSE`](LICENSE). Third-party reference data remains subject to the terms of its original
publishers, as listed above.

## Contributing / security

Issues and pull requests are welcome; see [`CONTRIBUTING.md`](CONTRIBUTING.md) for the ground rules
(counts are generated, not edited; new claims need evidence in the register; the banned-claim
lexicon is enforced by tests). Please do not open a public issue for a security problem — see
[`SECURITY.md`](SECURITY.md).
