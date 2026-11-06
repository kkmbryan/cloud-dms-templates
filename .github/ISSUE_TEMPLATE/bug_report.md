---
name: Bug report
about: Report a problem with a template, a module, a script or the documentation
title: "fix: "
labels: bug
assignees: ""
---

> **Security vulnerabilities:** don't open an issue. Use the repository's **Security** tab → **Report a vulnerability** (see SECURITY.md).
>
> **Redact before you post:** replace project IDs and numbers, IP addresses, service account emails, DMS operation IDs, bucket, instance and host names with placeholders such as `my-gcp-project-01`, `PROJECT_NUMBER` and `SOURCE_IP`. Never paste `terraform.tfvars`, state or plan files, passwords, keys or certificates.

## Description

<!-- What happened, and what did you expect to happen? -->

## Affected Component

- [ ] `templates/01-live-migration-gce-cdc`
- [ ] `templates/02-backup-migration-gcs-cdc`
- [ ] A module in `modules/` (which one?):
- [ ] A script in `scripts/` or `templates/*/scripts/`
- [ ] Documentation (English or `*.zh-CN.md`)

## Steps to Reproduce

1.
2.
3.

## Environment

- Terraform version (`terraform version`):
- Google provider version (from `.terraform.lock.hcl`):
- Google Cloud CLI version (`gcloud version`):
- Scenario and seed type (`dump_type`):
- `target_database_version` and `destination_mode`:
- `connectivity_type` (PSC or PSA):

## Error Output (Redacted)

```text
Paste the redacted error message here.
```

## Additional Context

<!-- Anything else: workarounds you tried, related issues, documentation links. -->
