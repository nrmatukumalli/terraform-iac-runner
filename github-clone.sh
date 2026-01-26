#!/usr/bin/env bash

set -euo pipefail

# Script to authenticate with GitHub App and clone repository
# Usage: ./github-clone.sh [options]

# Default values
SECRET_NAME=""
REPO_URL=""
TARGET_DIR=""
REF_TYPE=""
REF_VALUE=""
AWS_REGION="us-east-1"
VERBOSE=false

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1" >&2
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1" >&2
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_debug() {
    if [[ "$VERBOSE" == "true" ]]; then
        echo -e "[DEBUG] $1" >&2
    fi
}

# Show usage information
usage() {
    cat << EOF
GitHub App Repository Clone Script

USAGE:
    $0 [OPTIONS]

OPTIONS:
    -s, --secret-name SECRET_NAME    AWS Secrets Manager secret name containing GitHub App credentials
    -r, --repo REPO_URL             Repository URL (e.g., owner/repo or full GitHub URL)
    -d, --directory TARGET_DIR      Target directory to clone repository
    -t, --ref-type TYPE             Reference type: branch, tag, or commit
    -v, --ref-value VALUE           Reference value (branch name, tag name, or commit hash)
    --aws-region REGION             AWS region for Secrets Manager (default: us-east-1)
    --verbose                       Enable verbose logging
    -h, --help                      Show this help message

EXAMPLES:
    # Clone main branch
    $0 -s "github-app-secrets" -r "owner/repo" -d "./cloned-repo" -t "branch" -v "main"
    
    # Clone specific tag
    $0 -s "github-app-secrets" -r "owner/repo" -d "./cloned-repo" -t "tag" -v "v1.0.0"
    
    # Clone specific commit
    $0 -s "github-app-secrets" -r "owner/repo" -d "./cloned-repo" -t "commit" -v "abc123def456"

SECRET FORMAT:
    The AWS secret should contain JSON with the following structure:
    {
        "app_id": "123456",
        "private_key": "-----BEGIN RSA PRIVATE KEY-----\n...\n-----END RSA PRIVATE KEY-----",
        "installation_id": "12345678"
    }

REQUIREMENTS:
    - aws CLI configured with appropriate permissions
    - jq for JSON parsing
    - git for repository operations
    - openssl for JWT generation
    - curl for GitHub API calls
EOF
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -s|--secret-name)
                SECRET_NAME="$2"
                shift 2
                ;;
            -r|--repo)
                REPO_URL="$2"
                shift 2
                ;;
            -d|--directory)
                TARGET_DIR="$2"
                shift 2
                ;;
            -t|--ref-type)
                REF_TYPE="$2"
                shift 2
                ;;
            -v|--ref-value)
                REF_VALUE="$2"
                shift 2
                ;;
            --aws-region)
                AWS_REGION="$2"
                shift 2
                ;;
            --verbose)
                VERBOSE=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
}

# Validate required parameters
validate_params() {
    local missing_params=()
    
    [[ -z "$SECRET_NAME" ]] && missing_params+=("secret-name")
    [[ -z "$REPO_URL" ]] && missing_params+=("repo")
    [[ -z "$TARGET_DIR" ]] && missing_params+=("directory")
    [[ -z "$REF_TYPE" ]] && missing_params+=("ref-type")
    [[ -z "$REF_VALUE" ]] && missing_params+=("ref-value")
    
    if [[ ${#missing_params[@]} -gt 0 ]]; then
        log_error "Missing required parameters: ${missing_params[*]}"
        usage
        exit 1
    fi
    
    # Validate ref-type
    if [[ ! "$REF_TYPE" =~ ^(branch|tag|commit)$ ]]; then
        log_error "Invalid ref-type: $REF_TYPE. Must be one of: branch, tag, commit"
        exit 1
    fi
}

# Check required dependencies
check_dependencies() {
    local missing_deps=()
    
    command -v aws >/dev/null 2>&1 || missing_deps+=("aws")
    command -v jq >/dev/null 2>&1 || missing_deps+=("jq")
    command -v git >/dev/null 2>&1 || missing_deps+=("git")
    command -v openssl >/dev/null 2>&1 || missing_deps+=("openssl")
    command -v curl >/dev/null 2>&1 || missing_deps+=("curl")
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_error "Missing required dependencies: ${missing_deps[*]}"
        exit 1
    fi
}

# Get GitHub App secrets from AWS Secrets Manager
get_github_secrets() {
    log_info "Retrieving GitHub App secrets from AWS Secrets Manager..."
    
    local secret_json
    secret_json=$(aws secretsmanager get-secret-value \
        --secret-id "$SECRET_NAME" \
        --region "$AWS_REGION" \
        --query 'SecretString' \
        --output text 2>/dev/null) || {
        log_error "Failed to retrieve secret '$SECRET_NAME' from AWS Secrets Manager"
        exit 1
    }
    
    # Parse and validate secret structure
    APP_ID=$(echo "$secret_json" | jq -r '.app_id // empty')
    PRIVATE_KEY=$(echo "$secret_json" | jq -r '.private_key // empty')
    INSTALLATION_ID=$(echo "$secret_json" | jq -r '.installation_id // empty')
    
    if [[ -z "$APP_ID" || -z "$PRIVATE_KEY" || -z "$INSTALLATION_ID" ]]; then
        log_error "Invalid secret format. Required fields: app_id, private_key, installation_id"
        exit 1
    fi
    
    log_success "Successfully retrieved GitHub App secrets"
    log_debug "App ID: $APP_ID"
    log_debug "Installation ID: $INSTALLATION_ID"
}

# Generate JWT token for GitHub App authentication
generate_jwt() {
    log_info "Generating JWT token for GitHub App authentication..."
    
    local header='{"alg":"RS256","typ":"JWT"}'
    local now=$(date +%s)
    local exp=$((now + 600)) # 10 minutes expiration
    
    local payload=$(jq -n \
        --arg iss "$APP_ID" \
        --arg iat "$now" \
        --arg exp "$exp" \
        '{iss: ($iss | tonumber), iat: ($iat | tonumber), exp: ($exp | tonumber)}')
    
    local header_b64=$(echo -n "$header" | openssl base64 -e -A | tr '+/' '-_' | tr -d '=')
    local payload_b64=$(echo -n "$payload" | openssl base64 -e -A | tr '+/' '-_' | tr -d '=')
    
    local signature
    signature=$(echo -n "${header_b64}.${payload_b64}" | \
        openssl dgst -sha256 -sign <(echo "$PRIVATE_KEY") | \
        openssl base64 -e -A | tr '+/' '-_' | tr -d '=')
    
    JWT_TOKEN="${header_b64}.${payload_b64}.${signature}"
    log_success "JWT token generated successfully"
}

# Get installation access token
get_installation_token() {
    log_info "Getting installation access token..."
    
    local response
    response=$(curl -s -X POST \
        -H "Authorization: Bearer $JWT_TOKEN" \
        -H "Accept: application/vnd.github.v3+json" \
        -H "User-Agent: terraform-iac-runner" \
        "https://api.github.com/app/installations/$INSTALLATION_ID/access_tokens") || {
        log_error "Failed to call GitHub API for installation token"
        exit 1
    }
    
    # Check for API errors
    if echo "$response" | jq -e '.message' >/dev/null 2>&1; then
        local error_msg=$(echo "$response" | jq -r '.message')
        log_error "GitHub API error: $error_msg"
        exit 1
    fi
    
    ACCESS_TOKEN=$(echo "$response" | jq -r '.token // empty')
    
    if [[ -z "$ACCESS_TOKEN" ]]; then
        log_error "Failed to extract access token from GitHub API response"
        log_debug "API Response: $response"
        exit 1
    fi
    
    log_success "Installation access token obtained successfully"
}

# Normalize repository URL
normalize_repo_url() {
    # Convert various repo URL formats to owner/repo format
    if [[ "$REPO_URL" =~ ^https://github\.com/([^/]+/[^/]+)/?.*$ ]]; then
        REPO_PATH="${BASH_REMATCH[1]}"
    elif [[ "$REPO_URL" =~ ^git@github\.com:([^/]+/[^/]+)\.git$ ]]; then
        REPO_PATH="${BASH_REMATCH[1]}"
    elif [[ "$REPO_URL" =~ ^[^/]+/[^/]+$ ]]; then
        REPO_PATH="$REPO_URL"
    else
        log_error "Invalid repository URL format: $REPO_URL"
        log_error "Supported formats: owner/repo, https://github.com/owner/repo, git@github.com:owner/repo.git"
        exit 1
    fi
    
    CLONE_URL="https://x-access-token:${ACCESS_TOKEN}@github.com/${REPO_PATH}.git"
    log_debug "Normalized repo path: $REPO_PATH"
}

# Clone repository with specified reference
clone_repository() {
    log_info "Cloning repository $REPO_PATH to $TARGET_DIR..."
    
    # Remove target directory if it exists
    if [[ -d "$TARGET_DIR" ]]; then
        log_warn "Target directory $TARGET_DIR already exists. Removing..."
        rm -rf "$TARGET_DIR"
    fi
    
    # Clone repository
    case "$REF_TYPE" in
        branch)
            log_info "Cloning branch: $REF_VALUE"
            git clone --branch "$REF_VALUE" --single-branch "$CLONE_URL" "$TARGET_DIR" || {
                log_error "Failed to clone branch '$REF_VALUE' from repository"
                exit 1
            }
            ;;
        tag)
            log_info "Cloning tag: $REF_VALUE"
            git clone --branch "$REF_VALUE" --single-branch "$CLONE_URL" "$TARGET_DIR" || {
                log_error "Failed to clone tag '$REF_VALUE' from repository"
                exit 1
            }
            ;;
        commit)
            log_info "Cloning repository and checking out commit: $REF_VALUE"
            git clone "$CLONE_URL" "$TARGET_DIR" || {
                log_error "Failed to clone repository"
                exit 1
            }
            
            # Checkout specific commit
            (cd "$TARGET_DIR" && git checkout "$REF_VALUE") || {
                log_error "Failed to checkout commit '$REF_VALUE'"
                exit 1
            }
            ;;
    esac
    
    # Clean up git remote URL to remove token
    (cd "$TARGET_DIR" && git remote set-url origin "https://github.com/${REPO_PATH}.git")
    
    log_success "Successfully cloned repository to $TARGET_DIR"
    
    # Show repository information
    local commit_hash
    local commit_message
    commit_hash=$(cd "$TARGET_DIR" && git rev-parse HEAD)
    commit_message=$(cd "$TARGET_DIR" && git log -1 --pretty=format:"%s")
    
    log_info "Repository information:"
    log_info "  Path: $REPO_PATH"
    log_info "  Reference: $REF_TYPE '$REF_VALUE'"
    log_info "  Commit: $commit_hash"
    log_info "  Message: $commit_message"
}

# Cleanup sensitive variables
cleanup() {
    unset JWT_TOKEN ACCESS_TOKEN PRIVATE_KEY APP_ID INSTALLATION_ID
}

# Main execution
main() {
    log_info "Starting GitHub App repository clone script..."
    
    parse_args "$@"
    validate_params
    check_dependencies
    
    # Set trap for cleanup
    trap cleanup EXIT
    
    get_github_secrets
    generate_jwt
    get_installation_token
    normalize_repo_url
    clone_repository
    
    log_success "Script completed successfully!"
}

# Execute main function with all arguments
main "$@"