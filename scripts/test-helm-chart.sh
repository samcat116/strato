#!/bin/bash

# Comprehensive Helm Chart Testing Script
# This script can be run locally to validate the Helm chart

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CHART_DIR="$PROJECT_ROOT/helm/strato-control-plane"
CI_VALUES_DIR="$CHART_DIR/ci"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Helper functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    # Check if helm is installed
    if ! command -v helm &> /dev/null; then
        log_error "Helm is not installed. Please install Helm 3.x"
        exit 1
    fi
    
    # Check helm version
    HELM_VERSION=$(helm version --short)
    log_info "Using $HELM_VERSION"
    
    # Check if kubeval is available (optional)
    if ! command -v kubeval &> /dev/null; then
        log_warning "kubeval not found. Template validation will be skipped."
        KUBEVAL_AVAILABLE=false
    else
        KUBEVAL_AVAILABLE=true
    fi
    
    log_success "Prerequisites check completed"
}

# Add required repositories
setup_repositories() {
    log_info "Setting up Helm repositories..."
    
    helm repo add bitnami https://charts.bitnami.com/bitnami
    helm repo update
    
    log_success "Repositories updated"
}

# Build chart dependencies
build_dependencies() {
    log_info "Building chart dependencies..."
    
    cd "$CHART_DIR"
    helm dependency build
    
    log_success "Dependencies built successfully"
}

# Lint the Helm chart
lint_chart() {
    log_info "Linting Helm chart..."
    
    cd "$PROJECT_ROOT"
    if helm lint "$CHART_DIR"; then
        log_success "Chart linting passed"
    else
        log_error "Chart linting failed"
        exit 1
    fi
}

# Template validation with different values
template_validation() {
    log_info "Validating chart templates..."
    
    local test_cases=(
        "default:default-values.yaml"
        "production:production-values.yaml"
        "external-db:external-db-values.yaml"
        "minimal:minimal-values.yaml"
    )
    
    for test_case in "${test_cases[@]}"; do
        IFS=':' read -r test_name values_file <<< "$test_case"
        
        log_info "Testing $test_name configuration..."
        
        # Generate template
        local output_file="/tmp/helm-test-$test_name.yaml"
        if helm template "strato-$test_name" "$CHART_DIR" \
            -f "$CI_VALUES_DIR/$values_file" > "$output_file"; then
            log_success "Template generation for $test_name successful"
            
            # Validate with kubeval if available
            if [[ "$KUBEVAL_AVAILABLE" == true ]]; then
                if kubeval "$output_file"; then
                    log_success "Template validation for $test_name passed"
                else
                    log_warning "Template validation for $test_name failed"
                fi
            fi
        else
            log_error "Template generation for $test_name failed"
            exit 1
        fi
    done
}

# Security checks
security_checks() {
    log_info "Running security checks..."
    
    # Check for hardcoded secrets in templates
    log_info "Checking for hardcoded secrets..."
    if grep -r "password.*:" "$CHART_DIR/templates/" | grep -v "secretKeyRef" | grep -v "valueFrom" | grep -v "# "; then
        log_error "Potential hardcoded secrets found in templates!"
        exit 1
    else
        log_success "No hardcoded secrets found"
    fi
    
    # Check for proper secret usage
    log_info "Validating secret references..."
    local secret_refs=$(grep -r "secretKeyRef\|valueFrom" "$CHART_DIR/templates/" | wc -l)
    if [[ "$secret_refs" -gt 0 ]]; then
        log_success "Found $secret_refs proper secret references"
    else
        log_warning "No secret references found - verify if secrets are properly used"
    fi
    
    # Check for security contexts
    log_info "Checking security contexts..."
    if grep -r "securityContext\|runAsNonRoot" "$CHART_DIR/templates/" > /dev/null; then
        log_success "Security contexts found in templates"
    else
        log_warning "No security contexts found - consider adding them for production"
    fi
}

# Validate chart metadata
validate_metadata() {
    log_info "Validating chart metadata..."
    
    # Check Chart.yaml
    if [[ -f "$CHART_DIR/Chart.yaml" ]]; then
        log_success "Chart.yaml found"
        
        # Validate required fields
        local required_fields=("name" "version" "description" "apiVersion")
        for field in "${required_fields[@]}"; do
            if grep -q "^$field:" "$CHART_DIR/Chart.yaml"; then
                log_success "Required field '$field' found in Chart.yaml"
            else
                log_error "Required field '$field' missing from Chart.yaml"
                exit 1
            fi
        done
    else
        log_error "Chart.yaml not found"
        exit 1
    fi
    
    # Check values.yaml
    if [[ -f "$CHART_DIR/values.yaml" ]]; then
        log_success "values.yaml found"
    else
        log_error "values.yaml not found"
        exit 1
    fi
}

# Test different configuration scenarios
test_configurations() {
    log_info "Testing configuration scenarios..."
    
    # Test with SpiceDB disabled
    log_info "Testing with SpiceDB disabled..."
    if helm template strato-no-spicedb "$CHART_DIR" \
        --set spicedb.enabled=false > /dev/null; then
        log_success "Configuration with SpiceDB disabled works"
    else
        log_error "Configuration with SpiceDB disabled failed"
        exit 1
    fi
    
    # Test with PostgreSQL disabled
    log_info "Testing with PostgreSQL disabled..."
    if helm template strato-no-postgres "$CHART_DIR" \
        --set postgresql.enabled=false \
        --set externalDatabase.host=external.postgres.com > /dev/null; then
        log_success "Configuration with PostgreSQL disabled works"
    else
        log_error "Configuration with PostgreSQL disabled failed"
        exit 1
    fi
    
    # Test with NetworkPolicy enabled
    log_info "Testing with NetworkPolicy enabled..."
    if helm template strato-netpol "$CHART_DIR" \
        --set networkPolicy.enabled=true > /dev/null; then
        log_success "Configuration with NetworkPolicy enabled works"
    else
        log_error "Configuration with NetworkPolicy enabled failed"
        exit 1
    fi
}

# Generate documentation
generate_docs() {
    log_info "Generating documentation..."
    
    # Generate README for values
    if command -v helm-docs &> /dev/null; then
        cd "$CHART_DIR"
        helm-docs
        log_success "Documentation generated with helm-docs"
    else
        log_warning "helm-docs not found. Skipping documentation generation."
        log_info "Install helm-docs: https://github.com/norwoodj/helm-docs"
    fi
}

# Main execution
main() {
    echo "========================================="
    echo "     Strato Helm Chart Test Suite"
    echo "========================================="
    echo
    
    check_prerequisites
    setup_repositories
    build_dependencies
    validate_metadata
    lint_chart
    template_validation
    test_configurations
    security_checks
    generate_docs
    
    echo
    log_success "All tests completed successfully! 🎉"
    echo
    echo "Next steps:"
    echo "  1. Review any warnings above"
    echo "  2. Test deployment in a real Kubernetes cluster"
    echo "  3. Run integration tests with actual Strato application image"
    echo "  4. Validate monitoring and observability features"
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi