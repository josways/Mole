#!/usr/bin/env bats

load helpers/common

setup() {
    mole_test_setup_project_root
}

@test "app protection data loads alone, defines no functions and is idempotent" {
    run /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
before_functions=$(declare -F)
source "$PROJECT_ROOT/lib/core/app_protection_data.sh"
[[ "$(declare -F)" == "$before_functions" ]] || exit 1
[[ ${#SYSTEM_CRITICAL_BUNDLES[@]} -gt 0 ]] || exit 1
[[ ${#APPLE_UNINSTALLABLE_APPS[@]} -gt 0 ]] || exit 1
[[ ${#DATA_PROTECTED_BUNDLES[@]} -gt 0 ]] || exit 1
[[ ${#ENDPOINT_SECURITY_BUNDLE_PREFIXES[@]} -gt 0 ]] || exit 1
before=$(declare -p SYSTEM_CRITICAL_BUNDLES APPLE_UNINSTALLABLE_APPS DATA_PROTECTED_BUNDLES ENDPOINT_SECURITY_BUNDLE_PREFIXES)
source "$PROJECT_ROOT/lib/core/app_protection_data.sh"
[[ "$(declare -p SYSTEM_CRITICAL_BUNDLES APPLE_UNINSTALLABLE_APPS DATA_PROTECTED_BUNDLES ENDPOINT_SECURITY_BUNDLE_PREFIXES)" == "$before" ]] || exit 1
EOF
    [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}
