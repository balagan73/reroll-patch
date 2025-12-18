#!/bin/bash
# reroll-patch.sh - Automates Drupal patch rerolling
# Version: 1.1

set -e  # Exit on any error

# State file to track reroll progress
STATE_FILE=".reroll-state"

# Help documentation
show_help() {
    cat << EOF
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
    the script with the same arguments or use --resume to continue.

ARGUMENTS
    patch-file      Path to the patch file to reroll (required)
    issue-number    Drupal.org issue number (required)
    target-branch   Git branch to rebase onto (optional, default: 8.x-1.x)

OPTIONS
    -h, --help      Show this help message and exit
    --resume        Resume from a previously interrupted reroll

EXAMPLES
    # Reroll a patch for issue 3267304 against the 8.x-1.x branch
    ./reroll-patch.sh 3267304.patch 3267304

    # After resolving conflicts, resume
    ./reroll-patch.sh --resume
    # or simply re-run with the same arguments
    ./reroll-patch.sh 3267304.patch 3267304

    # Reroll against a different branch
    ./reroll-patch.sh 3267304.patch 3267304 2.x

    # Show help
    ./reroll-patch.sh --help

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
       ./reroll-patch.sh <patch-file> <issue-number> [target-branch]
       OR
       ./reroll-patch.sh --resume

    The script will automatically detect the in-progress rebase and continue.

OUTPUT
    - <issue-number>-rerolled.patch - The new patch file
    - test-<issue-number> branch - Temporary branch (clean up after done)

REQUIREMENTS
    - Must be run from the root of a git repository
    - The patch file must contain a "Date:" field
    - Git must be installed and configured

NOTES
    - The script preserves your current branch and working directory state
    - Test branches are prefixed with "test-" to avoid conflicts
    - The script will not overwrite existing rerolled patch files
    - State is saved in .reroll-state file for resumability

SEE ALSO
    Drupal.org documentation on rerolling patches:
    https://www.drupal.org/docs/develop/git/using-git-to-contribute-to-drupal/working-with-patches/rerolling-patches

AUTHOR
    Generated for Drupal contribution workflow

EOF
}

# Check for help flag first
if [ "$1" == "-h" ] || [ "$1" == "--help" ]; then
    show_help
    exit 0
fi

# Check if we're in a git repository
if ! git rev-parse --git-dir > /dev/null 2>&1; then
    echo "❌ ERROR: Not in a git repository"
    echo "Please run this script from the root of your git project"
    exit 1
fi

# Function to save state
save_state() {
    echo "PATCH_FILE=$PATCH_FILE" > "$STATE_FILE"
    echo "ISSUE_NUMBER=$ISSUE_NUMBER" >> "$STATE_FILE"
    echo "TARGET_BRANCH=$TARGET_BRANCH" >> "$STATE_FILE"
    echo "TEST_BRANCH=$TEST_BRANCH" >> "$STATE_FILE"
}

# Function to load state
load_state() {
    if [ -f "$STATE_FILE" ]; then
        source "$STATE_FILE"
        return 0
    fi
    return 1
}

# Function to clear state
clear_state() {
    [ -f "$STATE_FILE" ] && rm "$STATE_FILE"
}

# Check if rebase is in progress
is_rebase_in_progress() {
    [ -d ".git/rebase-merge" ] || [ -d ".git/rebase-apply" ]
}

# Determine if we're in resume mode
RESUME_MODE=false
if [ "$1" == "--resume" ]; then
    RESUME_MODE=true
elif is_rebase_in_progress && load_state && [ -n "$1" ] && [ -n "$2" ]; then
    # Auto-detect resume if rebase is in progress, we have saved state,
    # AND user provided the same patch/issue arguments
    if [ "$1" == "$PATCH_FILE" ] && [ "$2" == "$ISSUE_NUMBER" ]; then
        RESUME_MODE=true
    fi
fi

# Resume mode logic
if [ "$RESUME_MODE" == "true" ] && is_rebase_in_progress; then
    # Load saved state if not already loaded
    if [ -z "$ISSUE_NUMBER" ] && ! load_state; then
        echo "❌ ERROR: Could not load saved state"
        echo "State file .reroll-state not found"
        exit 1
    fi

    echo "🔄 Resuming reroll for issue $ISSUE_NUMBER"
    echo "════════════════════════════════════════"
    echo ""

    # Check if there are still conflicts
    if git status | grep -q "Unmerged paths"; then
        echo "❌ ERROR: Conflicts still present"
        echo ""
        echo "Please resolve all conflicts first:"
        echo "  1. Edit the conflicted files"
        echo "  2. Stage them: git add ."
        echo "  3. Re-run: ./reroll-patch.sh --resume"
        exit 1
    fi

    # Check if files are staged
    if ! git diff --cached --quiet; then
        echo "✅ Changes staged, continuing rebase..."
    else
        echo "⚠️  No staged changes found, attempting to continue anyway..."
    fi

    if git rebase --continue; then
        echo "✅ Rebase completed successfully!"
        echo ""
    else
        echo "❌ Rebase failed. Please check for remaining conflicts."
        exit 2
    fi

    # Continue to patch generation below
elif [ "$RESUME_MODE" == "true" ]; then
    echo "❌ ERROR: No rebase in progress"
    exit 1
else
    # Normal mode - validate arguments
    PATCH_FILE="$1"
    ISSUE_NUMBER="$2"
    TARGET_BRANCH="${3:-8.x-1.x}"  # Default to 8.x-1.x if not specified
    TEST_BRANCH="test-$ISSUE_NUMBER"

    if [ -z "$PATCH_FILE" ] || [ -z "$ISSUE_NUMBER" ]; then
        echo "❌ ERROR: Missing required arguments"
        echo ""
        echo "Usage: ./reroll-patch.sh <patch-file> <issue-number> [target-branch]"
        echo "       ./reroll-patch.sh --help for more information"
        echo ""
        echo "Example: ./reroll-patch.sh 3267304.patch 3267304 8.x-1.x"
        exit 1
    fi

    # Check if patch file exists
    if [ ! -f "$PATCH_FILE" ]; then
        echo "❌ ERROR: Patch file '$PATCH_FILE' not found"
        exit 1
    fi

    # Extract patch date from the patch file
    PATCH_DATE=$(grep "^Date:" "$PATCH_FILE" | head -1 | sed 's/Date: //')
    if [ -z "$PATCH_DATE" ]; then
        echo "❌ ERROR: Could not find Date field in patch file"
        echo "The patch file must contain a 'Date:' field"
        exit 1
    fi

    # Save state for potential resume
    save_state

    echo "📋 Rerolling Patch"
    echo "=================="
    echo "📄 Patch file: $PATCH_FILE"
    echo "🔢 Issue number: $ISSUE_NUMBER"
    echo "🎯 Target branch: $TARGET_BRANCH"
    echo "📅 Patch date: $PATCH_DATE"
    echo ""

    # Step 1: Ensure we're on the target branch
    echo "🔄 Switching to $TARGET_BRANCH..."
    if ! git checkout "$TARGET_BRANCH"; then
        echo "❌ ERROR: Could not checkout branch '$TARGET_BRANCH'"
        echo "Make sure the branch exists"
        clear_state
        exit 1
    fi

    # Step 2: Check if patch already applies (no reroll needed)
    echo "🔍 Checking if patch applies cleanly..."
    if git apply --check "$PATCH_FILE" 2>/dev/null; then
        echo "✅ SUCCESS: Patch applies cleanly! No reroll needed."
        echo ""
        echo "ℹ️  You can apply this patch with: git apply $PATCH_FILE"
        clear_state
        exit 0
    fi
    echo "❌ Patch doesn't apply. Proceeding with reroll..."
    echo ""

    # Step 3: Find the commit closest to the patch date
    echo "🔍 Finding historical commit from patch date..."
    HISTORICAL_COMMIT=$(git log --before="$PATCH_DATE" --format="%H" -1)
    if [ -z "$HISTORICAL_COMMIT" ]; then
        echo "❌ ERROR: Could not find a commit before the patch date"
        echo "The patch might be older than your git history"
        clear_state
        exit 1
    fi
    HISTORICAL_COMMIT_SHORT=$(echo $HISTORICAL_COMMIT | cut -c1-7)
    echo "📌 Found commit: $HISTORICAL_COMMIT_SHORT"
    echo ""

    # Step 4: Create test branch from historical commit
    echo "🌿 Creating test branch: $TEST_BRANCH"

    # Check if test branch already exists
    if git rev-parse --verify "$TEST_BRANCH" >/dev/null 2>&1; then
        echo "⚠️  WARNING: Branch '$TEST_BRANCH' already exists"
        echo "Do you want to delete it and continue? (y/n)"
        read -r response
        if [ "$response" != "y" ]; then
            echo "Aborted."
            clear_state
            exit 1
        fi
        git branch -D "$TEST_BRANCH"
    fi

    git checkout -b "$TEST_BRANCH" "$HISTORICAL_COMMIT"
    echo ""

    # Step 5: Apply patch to old code
    echo "📝 Applying patch to historical code..."
    if ! git apply --index "$PATCH_FILE"; then
        echo "❌ ERROR: Patch doesn't even apply to historical code!"
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
    echo "✅ Patch applied to historical code"
    echo ""

    # Step 6: Commit the changes
    echo "💾 Committing patch..."
    git commit -m "Applying patch from issue $ISSUE_NUMBER"
    echo ""

    # Step 7: Rebase onto current branch
    echo "🔀 Rebasing onto $TARGET_BRANCH..."
    echo "This may take a moment..."
    if git rebase "$TARGET_BRANCH"; then
        echo "✅ Rebase successful! No conflicts."
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
        echo "   3. Re-run this script:     ./reroll-patch.sh $PATCH_FILE $ISSUE_NUMBER $TARGET_BRANCH"
        echo "      OR"
        echo "      Resume:                 ./reroll-patch.sh --resume"
        echo ""
        echo "To abort the rebase:          git rebase --abort"
        echo ""
        exit 2
    fi
fi

# Step 8: Generate rerolled patch
OUTPUT_PATCH="${ISSUE_NUMBER}-rerolled.patch"

# Check if output patch already exists
if [ -f "$OUTPUT_PATCH" ]; then
    echo "⚠️  WARNING: File '$OUTPUT_PATCH' already exists"
    echo "Do you want to overwrite it? (y/n)"
    read -r response
    if [ "$response" != "y" ]; then
        echo "Aborted. Patch not created."
        git checkout "$TARGET_BRANCH"
        clear_state
        exit 1
    fi
fi

echo "📄 Generating rerolled patch: $OUTPUT_PATCH"
git diff "$TARGET_BRANCH" "$TEST_BRANCH" > "$OUTPUT_PATCH"
echo ""

# Step 9: Verify the new patch applies
echo "✅ Verifying rerolled patch..."
git checkout "$TARGET_BRANCH"
if git apply --check "$OUTPUT_PATCH"; then
    echo "✅ SUCCESS! Rerolled patch applies cleanly."
    echo ""
    echo "📊 Results"
    echo "=========="

    # Check file size
    SIZE=$(wc -c < "$OUTPUT_PATCH")
    echo "📄 New patch: $OUTPUT_PATCH"
    echo "📊 Patch size: $SIZE bytes"

    if [ "$SIZE" -eq 0 ]; then
        echo "⚠️  WARNING: Patch file is empty!"
    fi

    echo ""
    echo "📋 Next Steps"
    echo "============="
    echo "1. Review the patch:     cat $OUTPUT_PATCH"
    echo "2. Apply it:             git apply $OUTPUT_PATCH"
    echo "3. Test your changes"
    echo "4. Upload to drupal.org issue #$ISSUE_NUMBER"
    echo "5. Clean up:             git branch -D $TEST_BRANCH"
else
    echo "❌ ERROR: Rerolled patch doesn't apply!"
    echo "This shouldn't happen. Please check the git history."
fi

echo ""
echo "🧹 Cleanup"
echo "=========="
echo "Test branch '$TEST_BRANCH' has been created."
echo "To remove it:  git branch -D $TEST_BRANCH"

# Clear state on successful completion
clear_state
