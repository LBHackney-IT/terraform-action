# Terraform Action for AWS
Configures credentials and runs terraform commands in a Github Action

# Usage
Use this when following feature branch development (Guide TBC) and want to deploy IAC using Terraform

Plans run on pull requests, and applies run on merges

# Example Workflow
```YAML
name: OIDC Authentication

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
      - uses: ./.github/actions/oidc-auth
        with: 
          role_arn: ${{ secrets.DEV_ROLE_ARN }}
          environment: 'dev'
          aws_deploy_region: 'eu-west-2'
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
      - uses: /.github/actions/oidc-auth@main
        with: 
          role_arn: ${{ secrets.PROD_ROLE_ARN }}
          environment: 'prod'
          aws_deploy_region: 'eu-west-2'
          aws_access_key: ${{ secrets.PROD_AWS_ACCESS_KEY }}
          aws_secret_key: ${{ secrets.PROD_AWS_SECRET_KEY }}
          github_token: ${{secrets.GITHUB_TOKEN}}

```
