#!/bin/bash
# reroll-patch.sh - Automates Drupal patch rerolling
# Version: 2.0

set -euo pipefail

# Global state
STATE_FILE=".reroll-state"
FORCE=false
ORIGINAL_BRANCH=""
CLEANUP_DONE=false

# ═══════════════════════════════════════════════════════════════════════
# Logging helpers
# ═══════════════════════════════════════════════════════════════════════

log_info()    { echo "ℹ️  $*"; }
log_success() { echo "✅ $*"; }
log_error()   { echo "❌ ERROR: $*"; }
log_warning() { echo "⚠️  WARNING: $*"; }

# ═══════════════════════════════════════════════════════════════════════
# State management
# ═══════════════════════════════════════════════════════════════════════

save_state() {
    cat > "$STATE_FILE" <<EOF
PATCH_FILE=$PATCH_FILE
ISSUE_NUMBER=$ISSUE_NUMBER
TARGET_BRANCH=$TARGET_BRANCH
TEST_BRANCH=$TEST_BRANCH
ORIGINAL_BRANCH=$ORIGINAL_BRANCH
EOF
}

load_state() {
    if [ ! -f "$STATE_FILE" ]; then
        return 1
    fi
    while IFS='=' read -r key value; do
        case "$key" in
            PATCH_FILE)       PATCH_FILE="$value" ;;
            ISSUE_NUMBER)     ISSUE_NUMBER="$value" ;;
            TARGET_BRANCH)    TARGET_BRANCH="$value" ;;
            TEST_BRANCH)      TEST_BRANCH="$value" ;;
            ORIGINAL_BRANCH)  ORIGINAL_BRANCH="$value" ;;
        esac
    done < "$STATE_FILE"
}

clear_state() {
    [ -f "$STATE_FILE" ] && rm "$STATE_FILE"
}

is_rebase_in_progress() {
    [ -d ".git/rebase-merge" ] || [ -d ".git/rebase-apply" ]
}

# ═══════════════════════════════════════════════════════════════════════
# Branch save/restore and cleanup
# ═══════════════════════════════════════════════════════════════════════

save_original_branch() {
    ORIGINAL_BRANCH=$(git rev-parse --abbrev-ref HEAD)
    if [ "$ORIGINAL_BRANCH" == "HEAD" ]; then
        ORIGINAL_BRANCH=$(git rev-parse HEAD)
    fi
}

restore_original_branch() {
    if [ -n "$ORIGINAL_BRANCH" ]; then
        git checkout -q "$ORIGINAL_BRANCH" 2>/dev/null || true
    fi
}

cleanup_on_exit() {
    if [ "$CLEANUP_DONE" = true ]; then
        return
    fi
    CLEANUP_DONE=true

    # Only restore if we're not in a rebase (user needs to resolve conflicts)
    if ! is_rebase_in_progress; then
        restore_original_branch
    fi
}

trap cleanup_on_exit EXIT INT TERM

# ═══════════════════════════════════════════════════════════════════════
# Confirm prompt (respects --force)
# ═══════════════════════════════════════════════════════════════════════

confirm_or_abort() {
    local message="$1"
    if [ "$FORCE" = true ]; then
        return 0
    fi
    echo "$message (y/n)"
    read -r response
    if [ "$response" != "y" ]; then
        echo "Aborted."
        exit 1
    fi
}

# ═══════════════════════════════════════════════════════════════════════
# Core workflow functions
# ═══════════════════════════════════════════════════════════════════════

check_patch_applies() {
    echo "🔍 Checking if patch applies cleanly..."
    if git apply --check "$PATCH_FILE" 2>/dev/null; then
        log_success "Patch applies cleanly! No reroll needed."
        echo ""
        log_info "You can apply this patch with: git apply $PATCH_FILE"
        clear_state
        exit 0
    fi
    log_info "Patch doesn't apply cleanly. Proceeding with reroll..."
    echo ""
}

find_historical_commit() {
    local patch_date
    patch_date=$(grep "^Date:" "$PATCH_FILE" | head -1 | sed 's/Date: //') || true

    if [ -n "$patch_date" ]; then
        find_commit_by_date "$patch_date"
    else
        log_info "No Date field found — searching commit history..."
        find_commit_by_binary_search
    fi
}

find_commit_by_date() {
    local patch_date="$1"
    echo "📅 Found patch date: $patch_date"

    HISTORICAL_COMMIT=$(git log --before="$patch_date" --format="%H" -1)
    if [ -z "$HISTORICAL_COMMIT" ]; then
        log_error "Could not find a commit before the patch date"
        echo "The patch might be older than your git history"
        clear_state
        exit 1
    fi
    log_success "Found commit: ${HISTORICAL_COMMIT:0:7}"
    echo ""
}

find_commit_by_binary_search() {
    echo "   Using binary search through commit history..."

    local -a all_commits
    mapfile -t all_commits < <(git log --format="%H")
    local total=${#all_commits[@]}

    echo "   Searching through $total commits..."

    # Check oldest commit first
    local oldest="${all_commits[$((total - 1))]}"
    if ! git checkout -q "$oldest" 2>/dev/null || ! git apply --check "$PATCH_FILE" 2>/dev/null; then
        git checkout -q "$TARGET_BRANCH" 2>/dev/null || true
        log_error "Patch doesn't apply even to the oldest commit"
        echo ""
        echo "This could mean:"
        echo "  - The patch is for a different branch"
        echo "  - The patch file is corrupted"
        clear_state
        exit 1
    fi

    echo "   ✓ Patch applies to oldest commit, searching for most recent..."

    # Binary search: find most recent commit where patch applies
    local left=0 right=$((total - 1)) mid result_index=$right
    while [ $left -le $right ]; do
        mid=$(((left + right) / 2))
        echo "   Testing commit $((mid + 1))/$total..."

        if git checkout -q "${all_commits[$mid]}" 2>/dev/null && git apply --check "$PATCH_FILE" 2>/dev/null; then
            result_index=$mid
            right=$((mid - 1))
        else
            left=$((mid + 1))
        fi
    done

    HISTORICAL_COMMIT="${all_commits[$result_index]}"
    git checkout -q "$TARGET_BRANCH" 2>/dev/null || true

    log_success "Found most recent applicable commit: ${HISTORICAL_COMMIT:0:7} (commit $((result_index + 1))/$total)"
    echo ""
}

create_test_branch() {
    echo "🌿 Creating test branch: $TEST_BRANCH"

    if git rev-parse --verify "$TEST_BRANCH" >/dev/null 2>&1; then
        log_warning "Branch '$TEST_BRANCH' already exists"
        confirm_or_abort "Delete it and continue?"
        git branch -D "$TEST_BRANCH"
    fi

    git checkout -b "$TEST_BRANCH" "$HISTORICAL_COMMIT"
    echo ""
}

apply_patch_to_history() {
    echo "📝 Applying patch to historical code..."
    if git apply --index "$PATCH_FILE" 2>/dev/null; then
        log_success "Patch applied"
    elif git apply --3way --index "$PATCH_FILE"; then
        log_success "Patch applied (using 3-way merge)"
    else
        log_error "Patch doesn't apply to historical code!"
        echo ""
        echo "This could mean:"
        echo "  - The patch date is incorrect"
        echo "  - The patch is for a different branch"
        echo "  - The patch file is corrupted"
        echo ""
        echo "🧹 Cleaning up..."
        git checkout "$TARGET_BRANCH"
        git branch -D "$TEST_BRANCH"
        clear_state
        exit 1
    fi

    echo "💾 Committing patch..."
    git commit -m "Applying patch from issue $ISSUE_NUMBER"
    echo ""
}

rebase_onto_target() {
    echo "🔀 Rebasing onto $TARGET_BRANCH..."
    if git rebase "$TARGET_BRANCH"; then
        log_success "Rebase successful! No conflicts."
        echo ""
    else
        echo ""
        echo "⚠️  ════════════════════════════════════════════════════════"
        echo "⚠️  CONFLICTS DETECTED - Manual Resolution Required"
        echo "⚠️  ════════════════════════════════════════════════════════"
        echo ""
        echo "📝 To resolve conflicts:"
        echo "   1. Edit the conflicted files (look for <<<<<<< and >>>>>>>)"
        echo "   2. Stage your changes:     git add ."
        echo "   3. Re-run this script:     ./reroll-patch.sh --resume"
        echo ""
        echo "To abort the rebase:          git rebase --abort"
        echo ""
        exit 2
    fi
}

generate_output_filename() {
    local base="${ISSUE_NUMBER}-rerolled"
    if [ ! -f "${base}.patch" ] || [ "$FORCE" = true ]; then
        OUTPUT_PATCH="${base}.patch"
        return
    fi

    local counter=2
    while [ -f "${base}-${counter}.patch" ]; do
        counter=$((counter + 1))
    done
    OUTPUT_PATCH="${base}-${counter}.patch"
}

generate_rerolled_patch() {
    generate_output_filename

    echo "📄 Generating rerolled patch: $OUTPUT_PATCH"
    git diff -M "$TARGET_BRANCH" "$TEST_BRANCH" > "$OUTPUT_PATCH"
    echo ""

    # Verify
    echo "🔍 Verifying rerolled patch..."
    git checkout -q "$TARGET_BRANCH"
    if git apply --check "$OUTPUT_PATCH"; then
        log_success "Rerolled patch applies cleanly."
    else
        log_error "Rerolled patch doesn't apply! Please check the git history."
        exit 1
    fi

    # Report
    echo ""
    local size
    size=$(wc -c < "$OUTPUT_PATCH")
    echo "📊 Results"
    echo "=========="
    echo "📄 New patch: $OUTPUT_PATCH"
    echo "📊 Patch size: $size bytes"
    if [ "$size" -eq 0 ]; then
        log_warning "Patch file is empty!"
    fi
    echo ""
    echo "📋 Next Steps"
    echo "============="
    echo "1. Review the patch:     cat $OUTPUT_PATCH"
    echo "2. Apply it:             git apply $OUTPUT_PATCH"
    echo "3. Test your changes"
    echo "4. Upload to drupal.org issue #$ISSUE_NUMBER"
    echo "5. Clean up:             git branch -D $TEST_BRANCH"
}

handle_resume() {
    if [ -z "${ISSUE_NUMBER:-}" ] && ! load_state; then
        log_error "Could not load saved state"
        echo "State file .reroll-state not found"
        exit 1
    fi

    echo "🔄 Resuming reroll for issue $ISSUE_NUMBER"
    echo "════════════════════════════════════════"
    echo ""

    if git status | grep -q "Unmerged paths"; then
        log_error "Conflicts still present"
        echo ""
        echo "Please resolve all conflicts first:"
        echo "  1. Edit the conflicted files"
        echo "  2. Stage them: git add ."
        echo "  3. Re-run: ./reroll-patch.sh --resume"
        exit 1
    fi

    if ! git diff --cached --quiet; then
        log_success "Changes staged, continuing rebase..."
    else
        log_warning "No staged changes found, attempting to continue anyway..."
    fi

    if git rebase --continue; then
        log_success "Rebase completed!"
        echo ""
    else
        log_error "Rebase failed. Please check for remaining conflicts."
        exit 2
    fi
}

# ═══════════════════════════════════════════════════════════════════════
# Help
# ═══════════════════════════════════════════════════════════════════════

show_help() {
    cat << 'EOF'
reroll-patch.sh - Automate Drupal Patch Rerolling

SYNOPSIS
    ./reroll-patch.sh <patch-file> <issue-number> [target-branch]
    ./reroll-patch.sh --resume
    ./reroll-patch.sh -h|--help

DESCRIPTION
    Automates the process of rerolling a Drupal patch that no longer applies
    to the current codebase. This follows the official Drupal.org workflow:

    1. Checks if the patch applies cleanly (no reroll needed)
    2. Finds the historical commit when the patch was created
    3. Creates a test branch from that commit
    4. Applies the patch to the old code
    5. Rebases the changes onto the current branch
    6. Generates a new rerolled patch file
    7. Verifies the new patch applies

    RESUMABLE: If conflicts occur during rebase, resolve them and re-run
    the script with --resume to continue.

ARGUMENTS
    patch-file      Path to the patch file to reroll (required)
    issue-number    Drupal.org issue number (required)
    target-branch   Git branch to rebase onto (optional, default: 8.x-1.x)

OPTIONS
    -h, --help      Show this help message and exit
    -f, --force     Skip interactive prompts (auto-yes)
    --resume        Resume from a previously interrupted reroll

EXAMPLES
    # Reroll a patch for issue 3267304 against the 8.x-1.x branch
    ./reroll-patch.sh 3267304.patch 3267304

    # After resolving conflicts, resume
    ./reroll-patch.sh --resume

    # Reroll against a different branch
    ./reroll-patch.sh 3267304.patch 3267304 2.x

    # Non-interactive mode (overwrite existing files/branches)
    ./reroll-patch.sh -f 3267304.patch 3267304

EXIT CODES
    0   Success - patch rerolled or no reroll needed
    1   Error - invalid arguments or patch couldn't be applied
    2   Conflicts - manual resolution required

HANDLING CONFLICTS
    If the script exits with code 2, conflicts were detected during rebase.
    To resolve:

    1. Manually edit the conflicted files (marked with <<<<<<< and >>>>>>>)
    2. Stage the resolved files:
       git add .
    3. Re-run the script:
       ./reroll-patch.sh --resume

OUTPUT
    - <issue-number>-rerolled.patch - The new patch file
    - test-<issue-number> branch - Temporary branch (clean up after done)

REQUIREMENTS
    - Must be run from the root of a git repository
    - Git must be installed and configured

SEE ALSO
    https://www.drupal.org/docs/develop/git/using-git-to-contribute-to-drupal/working-with-patches/rerolling-patches
EOF
}

# ═══════════════════════════════════════════════════════════════════════
# Argument parsing
# ═══════════════════════════════════════════════════════════════════════

parse_args() {
    RESUME_MODE=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            -f|--force)
                FORCE=true
                shift
                ;;
            --resume)
                RESUME_MODE=true
                shift
                ;;
            *)
                break
                ;;
        esac
    done

    # Remaining positional args
    PATCH_FILE="${1:-}"
    ISSUE_NUMBER="${2:-}"
    TARGET_BRANCH="${3:-8.x-1.x}"
    TEST_BRANCH="${ISSUE_NUMBER:+test-$ISSUE_NUMBER}"
}

# ═══════════════════════════════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════════════════════════════

main() {
    parse_args "$@"

    # Must be in a git repository
    if ! git rev-parse --git-dir > /dev/null 2>&1; then
        log_error "Not in a git repository"
        echo "Please run this script from the root of your git project"
        exit 1
    fi

    save_original_branch

    # Auto-detect resume: rebase in progress + saved state exists
    if ! $RESUME_MODE && is_rebase_in_progress; then
        local cli_patch="${PATCH_FILE:-}" cli_issue="${ISSUE_NUMBER:-}"
        if load_state; then
            # If user re-ran with same args, or no args, auto-resume
            if [ -z "$cli_patch" ] || { [ "$cli_patch" = "$PATCH_FILE" ] && [ "$cli_issue" = "$ISSUE_NUMBER" ]; }; then
                RESUME_MODE=true
            fi
        fi
    fi

    # Handle resume
    if $RESUME_MODE && is_rebase_in_progress; then
        handle_resume
        generate_rerolled_patch
        restore_original_branch
        clear_state
        return
    elif $RESUME_MODE; then
        log_error "No rebase in progress"
        exit 1
    fi

    # Normal mode - validate arguments
    if [ -z "$PATCH_FILE" ] || [ -z "$ISSUE_NUMBER" ]; then
        log_error "Missing required arguments"
        echo ""
        echo "Usage: ./reroll-patch.sh <patch-file> <issue-number> [target-branch]"
        echo "       ./reroll-patch.sh --help for more information"
        echo ""
        echo "Example: ./reroll-patch.sh 3267304.patch 3267304 8.x-1.x"
        exit 1
    fi

    if [ ! -f "$PATCH_FILE" ]; then
        log_error "Patch file '$PATCH_FILE' not found"
        exit 1
    fi

    save_state

    echo "📋 Rerolling Patch"
    echo "=================="
    echo "📄 Patch file: $PATCH_FILE"
    echo "🔢 Issue number: $ISSUE_NUMBER"
    echo "🎯 Target branch: $TARGET_BRANCH"
    echo ""

    # Switch to target branch
    echo "🔄 Switching to $TARGET_BRANCH..."
    if ! git checkout "$TARGET_BRANCH"; then
        log_error "Could not checkout branch '$TARGET_BRANCH'"
        echo "Make sure the branch exists"
        clear_state
        exit 1
    fi

    check_patch_applies
    find_historical_commit
    create_test_branch
    apply_patch_to_history
    rebase_onto_target
    generate_rerolled_patch
    restore_original_branch

    echo ""
    echo "🧹 Cleanup"
    echo "=========="
    echo "Test branch '$TEST_BRANCH' has been created."
    echo "To remove it:  git branch -D $TEST_BRANCH"

    clear_state
}

main "$@"
