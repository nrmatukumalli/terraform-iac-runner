
# Build stage - contains all build dependencies and tools
FROM debian:bookworm-slim AS builder

ARG DEBIAN_FRONTEND=noninteractive
ARG TARGETARCH

# Install build tools and dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl wget jq git gnupg unzip tar bash \
    && rm -rf /var/lib/apt/lists/*

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
      
############################################
# Trivy (Aqua Security official APT repo)
############################################
# Reference: https://aquasecurity.github.io/trivy/v0.55/getting-started/installation/
RUN install -m 0755 -d /etc/apt/keyrings && \
    curl -fsSL https://aquasecurity.github.io/trivy-repo/deb/public.key | gpg --dearmor -o /etc/apt/keyrings/trivy.gpg && \
    chmod a+r /etc/apt/keyrings/trivy.gpg && \
    . /etc/os-release && \
    echo "deb [signed-by=/etc/apt/keyrings/trivy.gpg] https://aquasecurity.github.io/trivy-repo/deb ${VERSION_CODENAME} main" \
      > /etc/apt/sources.list.d/trivy.list

############################################
# TFLint (GitHub latest release)
############################################
# Reference: https://github.com/terraform-linters/tflint#installation
RUN set -eux; \
    if [ "${TARGETARCH}" = "linux/amd64" ]; then TFLINT_ARCH=amd64; elif [ "${TARGETARCH}" = "linux/arm64" ]; then TFLINT_ARCH=arm64; else TFLINT_ARCH=amd64; fi ; \
    TFLINT_URL="https://github.com/terraform-linters/tflint/releases/latest/download/tflint_linux_${TFLINT_ARCH}.zip"; \
    curl -fsSL -o /tmp/tflint.zip "$TFLINT_URL"; \
    unzip -d /usr/local/bin /tmp/tflint.zip; \
    rm -f /tmp/tflint.zip; \
    /usr/local/bin/tflint --version

############################################
# OPA (GitHub latest release)
############################################
# Reference: https://www.openpolicyagent.org/docs/latest/#running-opa
RUN set -eux; \
    if [ "${TARGETARCH}" = "linux/amd64" ]; then OPA_ARCH=amd64; elif [ "${TARGETARCH}" = "linux/arm64" ]; then OPA_ARCH=arm64; else OPA_ARCH=amd64; fi ; \
    OPA_URL="https://github.com/open-policy-agent/opa/releases/latest/download/opa_linux_${OPA_ARCH}"; \
    curl -fsSL -o /usr/local/bin/opa "$OPA_URL"; \
    chmod +x /usr/local/bin/opa; 
    #/usr/local/bin/opa version

# Install IAC Tools via APT
RUN apt-get update && apt-get install -y --no-install-recommends \
    terraform trivy \
    && rm -rf /var/lib/apt/lists/*

############################################
# Terraform provider cache (pre-populate)
############################################
ENV TF_PLUGIN_CACHE_DIR=/usr/local/terraform.d/plugin-cache
COPY build-cache.sh /tmp/build-cache.sh
RUN chmod +x /tmp/build-cache.sh && /tmp/build-cache.sh

# Final runtime stage - minimal runtime dependencies only
FROM debian:bookworm-slim AS runtime

ARG DEBIAN_FRONTEND=noninteractive

# Install only runtime dependencies (no build tools like curl, wget, unzip, etc.)
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates git bash jq curl wget unzip tar bash \
    && rm -rf /var/lib/apt/lists/*

# AWS CLI
RUN if [ "${TARGETARCH}" = "linux/amd64" ]; then ARCHITECTURE=x86_64; elif [ "${TARGETARCH}" = "linux/arm64" ]; then ARCHITECTURE=aarch64; else ARCHITECTURE=x86_64; fi ;\
    for i in {1..5}; do curl -LsS "https://awscli.amazonaws.com/awscli-exe-linux-${ARCHITECTURE}.zip" -o /tmp/awscli.zip && break || sleep 15; done ;\
    mkdir -p /usr/local/awscli ;\
    unzip -q /tmp/awscli.zip -d /usr/local/awscli ;\
    /usr/local/awscli/aws/install \
    && rm -rf /tmp/awscli.zip

# Copy installed binaries and tools from builder stage
COPY --from=builder /usr/bin/terraform /usr/bin/terraform
COPY --from=builder /usr/local/bin/tflint /usr/local/bin/tflint
COPY --from=builder /usr/local/bin/opa /usr/local/bin/opa
COPY --from=builder /usr/bin/trivy /usr/bin/trivy

# Copy Terraform provider cache
COPY --from=builder /usr/local/terraform.d/plugin-cache /usr/local/terraform.d/plugin-cache

# Set environment variables
ENV TF_PLUGIN_CACHE_DIR=/usr/local/terraform.d/plugin-cache \
    TF_IN_AUTOMATION=1 \
    TF_INPUT=0 \
    PAGER=cat \
    AWS_CSM_ENABLED=false \
    AWS_PAGER="" \
    AWS_DEFAULT_OUTPUT=json

# Set proper permissions and create workspace
RUN chmod -R a+rX /usr/local/terraform.d/plugin-cache && mkdir -p /workspace

WORKDIR /workspace

CMD ["/bin/sh", "-lc", "echo 'Versions:' && terraform -version && tflint --version && trivy --version && opa version && aws --version && bash"]