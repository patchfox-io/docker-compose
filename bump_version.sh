#!/bin/bash

# Script to automatically bump patch version in all pom.xml files using Maven Versions Plugin
# This is much safer than manual sed/awk manipulation

set -e  # Exit on any error

# ANSI color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check for required tools
if ! command_exists mvn; then
    print_error "Maven (mvn) command not found. Please install Maven."
    exit 1
fi

if ! command_exists find; then
    print_error "find command not found. Please install findutils."
    exit 1
fi

print_info "═══════════════════════════════════════"
print_info "MAVEN VERSIONS PLUGIN VERSION BUMP"
print_info "═══════════════════════════════════════"

# Find all directories with pom.xml files in top-level subdirectories
print_info "Searching for Maven projects in top-level subdirectories..."

# Find directories one level deep that contain pom.xml
PROJECT_DIRS=$(find . -maxdepth 2 -mindepth 2 -name "pom.xml" -type f -exec dirname {} \; | sort)

if [ -z "$PROJECT_DIRS" ]; then
    print_warning "No pom.xml files found in top-level subdirectories."
    exit 0
fi

print_info "Found Maven projects:"
echo "$PROJECT_DIRS" | while read -r dir; do
    echo "  - $dir"
done

echo ""

# Initialize counters
UPDATED_COUNT=0
PROCESSED_COUNT=0
FAILED_COUNT=0

# Process each Maven project
while read -r PROJECT_DIR; do
    if [ ! -f "$PROJECT_DIR/pom.xml" ]; then
        continue
    fi
    
    PROCESSED_COUNT=$((PROCESSED_COUNT + 1))
    print_info "Processing: $PROJECT_DIR"
    
    # Store current directory and change to project directory
    ORIGINAL_DIR=$(pwd)
    
    if ! cd "$PROJECT_DIR"; then
        print_error "Failed to enter directory: $PROJECT_DIR"
        FAILED_COUNT=$((FAILED_COUNT + 1))
        continue
    fi
    
    # Extract current version using Maven help plugin
    CURRENT_VERSION=$(mvn help:evaluate -Dexpression=project.version -q -DforceStdout -Dorg.slf4j.simpleLogger.defaultLogLevel=WARN 2>/dev/null | tail -n1)
    
    if [ -z "$CURRENT_VERSION" ] || [ "$CURRENT_VERSION" = "null object or invalid expression" ]; then
        print_warning "⚠ Could not determine current version for: $PROJECT_DIR (skipping)"
        FAILED_COUNT=$((FAILED_COUNT + 1))
        cd "$ORIGINAL_DIR"
        continue
    fi
    
    print_info "Current version: $CURRENT_VERSION"
    
    # Validate semantic versioning format (handle SNAPSHOT versions)
    CLEAN_VERSION="$CURRENT_VERSION"
    if [[ "$CURRENT_VERSION" == *"-SNAPSHOT" ]]; then
        CLEAN_VERSION="${CURRENT_VERSION%-SNAPSHOT}"
        print_info "Detected SNAPSHOT version, will increment: $CLEAN_VERSION"
    fi
    
    if [[ ! "$CLEAN_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        print_warning "⚠ Version '$CURRENT_VERSION' in $PROJECT_DIR does not follow semantic versioning (major.minor.patch). Skipping."
        FAILED_COUNT=$((FAILED_COUNT + 1))
        cd "$ORIGINAL_DIR"
        continue
    fi
    
    # Calculate new patch version
    IFS='.' read -r major minor patch <<< "$CLEAN_VERSION"
    NEW_PATCH_VERSION="$major.$minor.$((patch + 1))"
    
    # Preserve SNAPSHOT suffix if it was present
    if [[ "$CURRENT_VERSION" == *"-SNAPSHOT" ]]; then
        NEW_VERSION="$NEW_PATCH_VERSION-SNAPSHOT"
    else
        NEW_VERSION="$NEW_PATCH_VERSION"
    fi
    
    print_info "New version: $NEW_VERSION"
    
    # Use Maven versions plugin to set the new version
    print_info "Running: mvn versions:set -DnewVersion=$NEW_VERSION"
    
    if mvn versions:set -DnewVersion="$NEW_VERSION" -DgenerateBackupPoms=false -Dorg.slf4j.simpleLogger.defaultLogLevel=WARN -q 2>/dev/null; then
        # Verify the change
        VERIFICATION_VERSION=$(mvn help:evaluate -Dexpression=project.version -q -DforceStdout -Dorg.slf4j.simpleLogger.defaultLogLevel=WARN 2>/dev/null | tail -n1)
        
        if [ "$VERIFICATION_VERSION" = "$NEW_VERSION" ]; then
            print_success "✓ Updated version: $CURRENT_VERSION → $NEW_VERSION in: $PROJECT_DIR"
            UPDATED_COUNT=$((UPDATED_COUNT + 1))
        else
            print_error "✗ Version verification failed in: $PROJECT_DIR"
            print_error "   Expected: $NEW_VERSION, Found: $VERIFICATION_VERSION"
            FAILED_COUNT=$((FAILED_COUNT + 1))
        fi
    else
        print_error "✗ Maven versions:set failed for: $PROJECT_DIR"
        FAILED_COUNT=$((FAILED_COUNT + 1))
    fi
    
    # Return to original directory
    cd "$ORIGINAL_DIR"
    echo ""
    
done < <(echo "$PROJECT_DIRS")

print_info "═══════════════════════════════════════"
print_info "VERSION BUMP SUMMARY"
print_info "═══════════════════════════════════════"

echo "Projects Processed: $PROCESSED_COUNT"
echo "Successfully Updated: $UPDATED_COUNT"
echo "Failed: $FAILED_COUNT"

if [ "$UPDATED_COUNT" -gt 0 ]; then
    print_success "🎉 Successfully bumped patch version in $UPDATED_COUNT project(s)!"
    print_info "💡 Tip: You can verify changes with: git diff"
    print_info "💡 Tip: Commit changes with: git add . && git commit -m 'Bump patch version'"
    
    if [ "$FAILED_COUNT" -gt 0 ]; then
        print_warning "⚠ $FAILED_COUNT project(s) failed to update. Check the logs above for details."
    fi
else
    print_warning "No versions were updated."
    if [ "$FAILED_COUNT" -gt 0 ]; then
        print_error "All $FAILED_COUNT project(s) failed to update. Common issues:"
        echo "  - Project doesn't follow semantic versioning (major.minor.patch)"
        echo "  - Maven configuration issues"
        echo "  - Invalid pom.xml structure"
    else
        print_warning "No valid Maven projects found with semantic versioning."
    fi
fi

echo ""
print_info "Script execution completed!" 
