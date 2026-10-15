# CI-Task

A small Python project used to practise building a complete **CI pipeline** and a **DevSecOps security pipeline** with GitHub Actions.

The application code is intentionally tiny (temperature conversion helpers) so the focus stays on the pipelines around it.

## Contents

- [The application](#the-application)
- [Repository layout](#repository-layout)
- [Run it locally](#run-it-locally)
- [Pipeline 1: Day 2 CI](#pipeline-1-day-2-ci)
- [Pipeline 2: Security Scan](#pipeline-2-security-scan)
- [Required secrets and variables](#required-secrets-and-variables)
- [Supply-chain hardening](#supply-chain-hardening)
- [Testing the pipelines](#testing-the-pipelines)

## The application

`temperature.py` provides three functions:

| Function | Description |
|----------|-------------|
| `celsius_to_fahrenheit(celsius)` | Converts °C to °F |
| `fahrenheit_to_celsius(fahrenheit)` | Converts °F to °C |
| `is_freezing(celsius)` | Returns `True` at or below 0 °C |

Tests live in `test_temperature.py` and run with pytest.

## Repository layout

```
.
├── temperature.py                  # application code
├── test_temperature.py             # pytest tests
├── requirements-dev.txt            # pinned dev dependencies
├── Dockerfile                      # minimal runtime image
├── .dockerignore
├── sonar-project.properties        # SonarQube Cloud configuration
├── PIPELINE.md                     # CI design document
└── .github/
    ├── dependabot.yml              # weekly updates for Actions (and pip)
    ├── actions/
    │   ├── prescan/action.yaml     # composite action: Gitleaks + TruffleHog + Trivy (fs)
    │   └── postscan/action.yaml    # composite action: Trivy (image)
    └── workflows/
        ├── ci.yml                  # test, package, verify, report
        └── security.yaml           # pre-scan, SonarQube, build, post-scan
```

## Run it locally

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements-dev.txt
pytest -v
```

Build and run the container:

```bash
docker build -t temp-app:local .
docker run --rm temp-app:local        # prints 212.0
```

## Pipeline 1: Day 2 CI

Defined in `.github/workflows/ci.yml`. The design is described in [PIPELINE.md](PIPELINE.md).

**Triggers**

- Push to `main` (ignored when only Markdown files or `docs/` change)
- Pull requests targeting `main`
- Manual run (`workflow_dispatch`) with inputs `python-version` (3.12 or 3.13) and `create-package` (boolean)
- Schedule: every Monday at 07:00 UTC

**Jobs**

```
test ──► package ──► verify
  │         │
  │         └──► pr-comment   (pull requests only)
  └────┬────┘
       ▼
    report                     (always runs)
```

| Job | Purpose |
|-----|---------|
| `test` | Runs pytest with pip caching, writes a JUnit report, prints a failure message when tests fail |
| `package` | Builds `dist/temperature-<version>.tar.gz` and exposes the version as a job output |
| `verify` | Downloads the package artifact (no checkout) and runs a smoke test |
| `report` | Runs even on failure or skip and writes a Markdown job summary |
| `pr-comment` | Comments on the pull request with the package version, using the minimum permission |

**Artifacts:** `test-report` (JUnit XML, kept 5 days) and `package` (the tarball).

## Pipeline 2: Security Scan

Defined in `.github/workflows/security.yaml`.

```
            ┌─► pre-scan (composite action)
            │     ├─ Gitleaks
            │     ├─ TruffleHog
            │     └─ Trivy (filesystem)
 push / PR ─┤
            └─► sonar (tests + coverage + SonarQube Cloud, quality gate)
                      │
                      ▼  (both must pass; skipped on pull requests)
                 build-image ──► post-scan (composite action: Trivy image scan)
```

| Stage | Tool | What it looks for |
|-------|------|-------------------|
| Pre-scan | **Gitleaks** | Secrets in source files and git history |
| Pre-scan | **TruffleHog** | Secrets, with verification against the real service |
| Pre-scan | **Trivy (fs)** | Vulnerable dependencies, misconfigurations, secrets in files |
| Code quality | **SonarQube Cloud** | Bugs, vulnerabilities, code smells, coverage, quality gate |
| Build | Docker | Builds and pushes the image to GHCR |
| Post-scan | **Trivy (image)** | Known CVEs in the built image, scanned by image reference |

The pipeline fails on HIGH and CRITICAL findings that have a fix available. Because of the `needs` dependencies, no image is built unless the pre-scan and the quality gate pass.

### Composite actions

| Action | Inputs |
|--------|--------|
| `.github/actions/prescan` | `github-token`, `scan-path`, `severity` |
| `.github/actions/postscan` | `image-ref`, `registry-username`, `registry-password`, `severity` |

Local composite actions are read from disk, so the calling job must run `actions/checkout` first.

## Required secrets and variables

Configure these under **Settings → Secrets and variables → Actions**.

| Name | Type | Used by |
|------|------|---------|
| `NOTIFY_TOKEN` | Secret | `ci.yml` (`report` job, a fake value is fine) |
| `REPORT_TITLE` | Variable | `ci.yml` (job summary heading) |
| `SONAR_TOKEN` | Secret | `security.yaml` (`sonar` job) |
| `GITHUB_TOKEN` | Provided automatically | Registry login, PR comments, scanners |

SonarQube Cloud must use **CI-based analysis**. Turn off Automatic Analysis under **Administration → Analysis Method**, otherwise the scan fails.

## Supply-chain hardening

CI pipelines run third-party code with access to tokens and secrets, so the project follows these rules:

- **Third-party actions are pinned to full commit SHAs** (with the version in a comment), because tags can be moved. This matters especially for security tools. In March 2026 the `trivy-action` tags were hijacked to steal credentials.
- **Workflow permissions are minimal.** The top level is `contents: read`, and extra permissions are granted per job (`packages: write` only for the build job).
- **User-controlled values** (branch names, PR numbers, inputs) are passed through `env:` and never interpolated into `run:` scripts.
- **Python test dependencies are pinned** and installed with `--only-binary :all:` so no `setup.py` code runs during installation.
- **The runtime image is minimal**: slim base image, non-root user, and unused packaging tools removed.
- **Dependabot** checks GitHub Actions weekly and proposes updates, including SHA bumps.

## Testing the pipelines

| Scenario | How | Expected result |
|----------|-----|-----------------|
| Green run | Push to `main` | All jobs pass, two artifacts, job summary |
| Docs-only change | Edit only a `.md` file | `ci.yml` does not run |
| Failing test | Break a test on a branch and open a PR | `test` fails, report still runs, package skipped |
| Leaked secret | Commit a **fake** key on a branch | `pre-scan` fails, `build-image` skipped |
| Vulnerable image | Use an old base image and run the workflow manually | `post-scan` fails with a CVE table |
| Manual run | Run `ci.yml` with Python 3.12 and `create-package` off | `package` and `verify` skipped, version shows `n/a` |

> Never use a real credential when testing the secret scanners.

## Author

Nada Adel, [@nadaadel50](https://github.com/nadaadel50)
