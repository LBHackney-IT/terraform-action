# Terraform Action for AWS
Configures credentials and runs terraform commands in a Github Action

# Usage
Use this when following feature branch development (Guide TBC) and want to deploy IAC using Terraform

Plans run on pull requests, and applies run on merges or a tag. 

# Inputs
```YAML
  backend_config:
    description: Location of the terraform config file, including filename
    required: true
  vars_file:
    description: Location of the TFVars file, including filename
    required: true
  aws_access_key: 
    description: AWS access key
    required: True
  aws_secret_key:
    description: AWS secret key
    required: True
  aws_region:
    description: Region to assume role with
    required: false
    default: eu-west-2
  plan_only:
    description: true if a plan is the only intended action
    type: boolean
    default: false
  github_token:    
    description: GitHub token for updating pull requests with plan output
    required: false
  role_arn:
    description: Full ARN of role to assume
    required: true
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
          role_arn: ${{ secrets.DEV_ROLE_ARN }}
          backend_config: backend/config.dev.tfbackend
          vars_file: tfvars/dev.tfvars
          aws_access_key: ${{ secrets.DEV_AWS_ACCESS_KEY}}
          aws_secret_key: ${{ secrets.DEV_AWS_SECRET_KEY }}
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
          role_arn: ${{ secrets.PROD_ROLE_ARN }}
          backend_config: backend/config.production.tfbackend
          vars_file: tfvars/production.tfvars
          aws_access_key: ${{ secrets.PROD_AWS_ACCESS_KEY }}
          aws_secret_key: ${{ secrets.PROD_AWS_SECRET_KEY }}
          github_token: ${{secrets.GITHUB_TOKEN}}

```
