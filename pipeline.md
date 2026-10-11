# Pipeline Design

# 1-Events
- push to main: verify every code change that lands on main.
- pull_request to main: catch problems before merging.
- workflow_dispatch: manual runs with a chosen Python version and an option to skip packaging.
- schedule (Mon 07:00 UTC): catches problems from outside changes when nobody has pushed.

# 2-Jobs and graph
- test      -> runs first
- package   -> needs test
- verify    -> needs package
- report    -> needs test + package, always runs
- pr-comment -> needs package, only on pull requests

    test ──► package ──► verify
      │         │
      │         └──► pr-comment (PRs only)
      └────┬────┘
           ▼
         report (always)

# 3-Artifact
temperature-<version>.tar.gz , plus the test-report JUnit XML.

# 4. CI / CD
Continuous Integration: it builds, tests and verifies every change but never releases or deploys anything.

## 5. Package when tests fail
It is skipped, because a package built from failing code is untrustworthy and must never be treated as a release candidate.