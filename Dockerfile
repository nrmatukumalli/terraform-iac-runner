
FROM debian:bookworm-slim

ARG DEBIAN_FRONTEND=noninteractive

# Base tools
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl wget jq git gnupg unzip tar bash \
    && rm -rf /var/lib/apt/lists

CMD ["/bin/sh", "-lc", "echo 'Versions:' && terraform -version && bash"]