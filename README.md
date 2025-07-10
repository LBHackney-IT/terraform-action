# Terraform Action for AWS
Configures credentials and runs terraform commands in a Github Action.

# Requirements
In order to use this action your terraform code will need to define the following variables:

hcl```
variable "repository_id" {
  type        = string
  description = "Id of the current repository, value is populated during acton run, please do not define in TFVars"
}

variable "repository" {
  type        = string
  description = "Name of the current repository, value is populated during acton run, please do not define in TFVars"
}
```
These should be used in the default_tags block of your AWS provider for the Repository and Repository_Id tags.

# Usage
Use this when following feature branch development (Guide TBC) and want to deploy IAC using Terraform

Plans run on pull requests, and applies run on merges or a tag

# Inputs
```YAML
  backend_config:
    description: Location of the terraform config file, including filename
    required: true
  vars_file:
    description: Location of the TFVars file, including filename
    required: true
  github_token:    
    description: GitHub token for updating pull requests with plan output
    required: false
  checkov_dir:
    description: Directory to run checkov checks against
    required: false
    default: '.'
```

# Example Workflow
```YAML
name: Example Workflow

on:
  push:
    branches: 
    - "main"
    - "feature/**"
    tags: ['v*']
    paths-ignore:
      - '**/README.md'
      - 'docs/**'

  workflow_dispatch:
    inputs:
      plan_only:
        type: boolean
        default: false 

jobs:
  DeployDev:
    name: Deploy to Dev 
    if: github.ref_name == 'feature/**'
    runs-on: ubuntu-latest
    steps:
      - name: checkout
        uses: actions/checkout@v3
      - uses: LBHackney-IT/terraform-action@v1
        with: 
          backend_config: backend/config.dev.tfbackend
          vars_file: tfvars/dev.tfvars
          github_token: ${{secrets.GITHUB_TOKEN}}

  DeployProd:
    name: Deploy to Production 
    if: github.ref_type == 'tag' && github.ref_name == 'main'
    runs-on: ubuntu-latest
    steps:
      - name: checkout
        uses: actions/checkout@v3
      - uses: LBHackney-IT/terraform-action@v1
        with: 
          backend_config: backend/config.production.tfbackend
          vars_file: tfvars/production.tfvars
          github_token: ${{secrets.GITHUB_TOKEN}}

```
