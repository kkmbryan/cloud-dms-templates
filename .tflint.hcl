# TFLint configuration, shared by CI (.github/workflows/terraform-ci.yml),
# pre-commit and local runs:
#   tflint --init --config="$(pwd)/.tflint.hcl"
#   tflint --recursive --config="$(pwd)/.tflint.hcl"
config {
  format = "compact"

  # Also evaluate the local modules called by the templates and examples, so
  # rules see the values passed in by each root.
  call_module_type = "all"
}

# Bundled Terraform language rules (unused declarations, typed variables,
# documented variables/outputs, required_version / required_providers, ...).
plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

# Google provider rules (invalid machine types, regions, enum values, ...).
plugin "google" {
  enabled = true
  version = "0.41.0"
  source  = "github.com/terraform-linters/tflint-ruleset-google"
}

rule "terraform_documented_variables" {
  enabled = true
}

rule "terraform_documented_outputs" {
  enabled = true
}

rule "terraform_naming_convention" {
  enabled = true
}

rule "terraform_unused_required_providers" {
  enabled = true
}
