#!/usr/bin/env bash

set -eux

mkdir -p "$TF_PLUGIN_CACHE_DIR"

cache_provider() {
  local src="$1"
  local name="$2"
  shift 2

  for ver in "$@"; do
    work="/tmp/tfmod_${name}_${ver}"
    mkdir -p "$work"
    if [ "$ver" = "latest" ]; then
      ver_line=""
    else
      ver_line="version = \"=${ver}\""
    fi
    cat > "$work/versions.tf" <<EOF
terraform {
  required_providers {
    ${name} = {
      source = "${src}"
      ${ver_line}
    }
  }
}
EOF
    
    TF_PLUGIN_CACHE_DIR="$TF_PLUGIN_CACHE_DIR" terraform -chdir="$work" init -upgrade -input=false -no-color
    rm -rf "$work"
  done
}

AWS_PROVIDER_VERSIONS='5.100.0 6.28.0 latest'
DATABRICKS_PROVIDER_VERSIONS='latest'
KUBERNETES_PROVIDER_VERSIONS='latest'

cache_provider "hashicorp/aws" "aws" ${AWS_PROVIDER_VERSIONS}
cache_provider "databricks/databricks" "databricks" ${DATABRICKS_PROVIDER_VERSIONS}
cache_provider "hashicorp/kubernetes" "kubernetes" ${KUBERNETES_PROVIDER_VERSIONS}
chmod -R a+rX "$TF_PLUGIN_CACHE_DIR"