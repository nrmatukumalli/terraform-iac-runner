
FROM debian:bookworm-slim

ARG DEBIAN_FRONTEND=noninteractive

# Base tools
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl wget jq git gnupg unzip tar bash \
    && rm -rf /var/lib/apt/lists


############################################
# Terraform (HashiCorp official APT repo)
############################################
# Reference: HashiCorp official install docs
# https://developer.hashicorp.com/terraform/tutorials/aws-get-started/install-cli
RUN install -m 0755 -d /etc/apt/keyrings && \
    curl -fsSL https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /etc/apt/keyrings/hashicorp.gpg && \
    chmod a+r /etc/apt/keyrings/hashicorp.gpg && \
    . /etc/os-release && \
    echo "deb [signed-by=/etc/apt/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com ${VERSION_CODENAME} main" \
      > /etc/apt/sources.list.d/hashicorp.list

# IAC Tools
RUN apt-get update && apt-get install -y --no-install-recommends \
    terraform \
    && rm -rf /var/lib/apt/lists/*


CMD ["/bin/sh", "-lc", "echo 'Versions:' && terraform -version && bash"]