## Summary

<!-- What does this pull request change, and why? Link the issue if there is one (for example, "Fixes #12"). -->

## Type of Change

- [ ] Bug fix
- [ ] New feature or variable
- [ ] Documentation
- [ ] CI or tooling
- [ ] Breaking change (existing deployments need a state move, a replacement or new inputs)

## How It Was Tested

<!--
Templates, scenarios and versions you tested (for example: Scenario 1, MYSQL_8_4, Terraform 1.11.x, provider 8.x).
For changes to deployed resources, paste a REDACTED plan summary: resource addresses and counts, no values.
-->

## Checklist

See [CONTRIBUTING.md](../CONTRIBUTING.md).

- [ ] `make fmt-check validate test` passes.
- [ ] `python3 scripts/ci/zh_parity_check.py` and `bash scripts/ci/customer_safety_check.sh` pass.
- [ ] `make lint` and `pre-commit run -a` pass, with no new TFLint, Trivy or gitleaks findings (each accepted finding is documented in `.trivyignore`).
- [ ] Changed shell scripts are ShellCheck-clean.
- [ ] Every changed Mermaid block renders on GitHub.
- [ ] Every changed English document has its `*.zh-CN.md` counterpart updated in this pull request, and both stay structurally in sync (headings, tables, alerts, links; code blocks byte-identical).
- [ ] Customer-safe: only placeholders (`my-gcp-project-01`, `PROJECT_NUMBER`, `europe-west2`); no real project IDs or numbers, IP addresses, operation IDs, service account emails, hostnames or customer names.
- [ ] No `terraform.tfvars`, `*.tfstate`, saved plan files, keys or certificates are committed.
- [ ] `TESTING.md` changes (if any) record only versions, scenarios and dates.
- [ ] The commit messages and the pull request title follow Conventional Commits.
- [ ] I submit this contribution under the Apache License 2.0.
