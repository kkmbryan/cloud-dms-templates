# Contributing

Thank you for your interest in improving these templates. This guide explains how to set up your environment, which checks a pull request must pass, and the rules that keep the repository safe to publish.

> [!NOTE]
> These templates are not an official Google product. Contributions are reviewed on a best-effort basis.

## 1. Development Setup

| Tool | Version | Used for |
| :--- | :--- | :--- |
| Terraform | `>= 1.11` (the root password uses a write-only argument) | `make fmt-check validate` |
| Google provider (`hashicorp/google`) | `>= 8.0, < 9.0` (pinned in each `versions.tf` and the template lock files) | `terraform init` |
| Google Cloud CLI (`gcloud`) | Current release | The `local-exec` steps and the `Makefile` targets |
| [pre-commit](https://pre-commit.com/) | Current release | Hooks in `.pre-commit-config.yaml` (fmt, validate, tflint, trivy, gitleaks, ShellCheck, zh-CN parity, customer-safety check, `terraform test`) |
| [TFLint](https://github.com/terraform-linters/tflint) | Current release | `make lint` with `.tflint.hcl` |
| [ShellCheck](https://www.shellcheck.net/) | Current release | Bash scripts in `scripts/` and `templates/*/scripts/` |

```bash
pip install pre-commit
pre-commit install
```

Don't change the provider constraint or the committed `.terraform.lock.hcl` files of the templates unless that is the purpose of your pull request. If you do, run `terraform init -upgrade` in both templates and commit both lock files.

## 2. Checks Every Pull Request Must Pass

Run these from the repository root before you open a pull request. CI runs `terraform fmt -check` and `terraform validate` on both templates.

```bash
make fmt-check validate
make test                                # terraform test with a mock provider
make lint
python3 scripts/ci/zh_parity_check.py    # EN and zh-CN docs stay in sync
bash scripts/ci/customer_safety_check.sh # no state files, tenant IDs or project numbers
pre-commit run -a
shellcheck scripts/source-prep/*.sh templates/*/scripts/*.sh
```

- **Terraform**: formatted, valid in both templates, and no new TFLint or Checkov findings. If a Checkov finding is intentional, suppress it inline with a `checkov:skip` comment that gives the reason.
- **Scripts**: ShellCheck-clean, `set -euo pipefail`, and no secrets on the command line or in logs.
- **Mermaid**: every `mermaid` block must render on GitHub. Quote labels that contain special characters, use `<br/>` for line breaks, and preview the file on GitHub (or with `@mermaid-js/mermaid-cli`) before you request review.

## 3. Documentation in Two Languages

Every user-facing document has an English file and a Simplified Chinese file (`*.zh-CN.md`) with a language switch line at the top.

- Change the English file and its `*.zh-CN.md` file **in the same pull request**.
- Keep them structurally in sync: the same headings (count and level), tables (rows and columns), alerts, links and Mermaid structure. Code blocks are byte-identical in both languages; only prose, table text and Mermaid labels are translated.
- If you can't write the translation, say so in the pull request and a maintainer will help. Don't merge one language without the other.

## 4. Customer-Safe Content

This repository is public. Everything in it must be safe to publish.

- Use placeholders only: `my-gcp-project-01`, `PROJECT_ID`, `PROJECT_NUMBER`, region `europe-west2`, `my-dms-staging-bucket`.
- Never commit real project IDs or numbers, IP addresses, DMS operation IDs, service account emails, bucket or instance names from a real environment, hostnames, or customer names.
- Never commit `terraform.tfvars`, `*.tfstate`, saved plan files (`tfplan`), `.terraform/` directories, private keys or certificates. `.gitignore` excludes the common ones; check `git status` before you commit.
- Redact logs and command output before you paste them into an issue or a pull request.
- [TESTING.md](TESTING.md) records only the versions, scenarios and dates that were tested, and the known limitations. Don't add identifiers, IP addresses or raw logs from your test environment.

## 5. Commits and Pull Requests

- Use [Conventional Commits](https://www.conventionalcommits.org/) for commit messages and pull request titles, for example `feat: ...`, `fix: ...`, `docs: ...`, `ci: ...`, `refactor: ...`.
- Keep one logical change per pull request, and branch from `main`.
- Fill in the pull request template, including the checklist.
- Describe how you tested the change. For changes that affect deployed resources, include the redacted `terraform plan` summary (resource counts and addresses, not values).
- Pull requests need an approval from a code owner (see `.github/CODEOWNERS`) before they are merged.

## 6. License

This project is licensed under the [Apache License 2.0](LICENSE). Contributions are accepted under the same license (inbound = outbound, as described in section 5 of the license). No Contributor License Agreement and no DCO sign-off (`Signed-off-by`) are required. By opening a pull request, you confirm that you have the right to submit the contribution under the Apache License 2.0.

## 7. Reporting Security Issues

Don't report vulnerabilities in issues or pull requests. Follow [SECURITY.md](SECURITY.md).
