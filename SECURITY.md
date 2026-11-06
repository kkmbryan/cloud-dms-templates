# Security Policy

> [!NOTE]
> These templates are not an official Google product. They are provided "as is", without warranty of any kind, under the [Apache 2.0 License](LICENSE). Vulnerabilities in Google Cloud services themselves (Cloud SQL, Database Migration Service, Compute Engine, Cloud Storage) are out of scope here; report them through the Google Vulnerability Reward Program at <https://bughunters.google.com/>.

## Supported Versions

Only the latest commit on the `main` branch is supported. Fixes are not backported to older commits or tags.

| Version | Supported |
| :--- | :--- |
| `main` (latest commit) | Yes |
| Older commits, tags and forks | No |

## Reporting a Vulnerability

Report vulnerabilities **only** through GitHub private vulnerability reporting:

1. Open the repository on GitHub and select the **Security** tab.
2. Select **Report a vulnerability**.
3. Describe the issue, the affected file(s), the impact, and the steps to reproduce it.

Don't open a public issue, pull request or discussion for a vulnerability, and don't report one by email.

Before you submit, **redact** everything that identifies your environment: project IDs and numbers, IP addresses, service account emails, DMS operation IDs, bucket names, instance names, hostnames, passwords, keys and certificates. Use placeholders such as `my-gcp-project-01`, `PROJECT_NUMBER`, `SOURCE_IP` and `SUBNET_CIDR`. Never attach `terraform.tfvars`, `*.tfstate` or saved plan files: they can contain secrets.

## What to Expect

- The maintainers acknowledge a report on a best-effort basis; there is no SLA.
- If the report is accepted, the fix lands on `main` and is credited in the GitHub security advisory unless you ask otherwise.
- Please give the maintainers a reasonable time to fix the issue before you disclose it publicly.

## Scope

| In scope | Out of scope |
| :--- | :--- |
| Terraform code in `modules/` and `templates/` that creates an insecure default (for example, a public IP, a firewall rule that is open too widely, or a secret written in clear text to an output) | Vulnerabilities in Google Cloud services, the Google Cloud CLI, Terraform or the Google provider (report them to their owners) |
| Scripts in `scripts/` and `templates/*/scripts/` (for example, command injection or secrets written to logs or world-readable files) | Insecure values that you set in your own `terraform.tfvars` or in a fork |
| Documentation that recommends an insecure practice | Findings that need an already compromised deployer identity or source VM |
| CI workflow configuration in `.github/` | Denial of service against your own project, and social engineering |

For the hardening guidance that comes with the templates, see [docs/security_hardening.md](docs/security_hardening.md).
