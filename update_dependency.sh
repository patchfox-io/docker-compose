#!/bin/bash

# Script to update any Maven dependency version in all pom.xml files
# Usage: ./update_dependency.sh [groupId] [artifactId] [version]

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
if ! command_exists sed; then
    print_error "sed command not found. Please install sed."
    exit 1
fi

if ! command_exists find; then
    print_error "find command not found. Please install findutils."
    exit 1
fi

# Get dependency information from command line arguments or prompt user
GROUP_ID=""
ARTIFACT_ID=""
NEW_VERSION=""

if [ $# -eq 3 ]; then
    GROUP_ID="$1"
    ARTIFACT_ID="$2"
    NEW_VERSION="$3"
elif [ $# -eq 0 ]; then
    echo -n "Enter the groupId (e.g., io.patchfox.db-entities): "
    read -r GROUP_ID
    echo -n "Enter the artifactId (e.g., db-entities): "
    read -r ARTIFACT_ID
    echo -n "Enter the new version: "
    read -r NEW_VERSION
else
    print_error "Usage: $0 [groupId] [artifactId] [version]"
    print_error "   or: $0 (to be prompted for values)"
    exit 1
fi

# Validate inputs
if [ -z "$GROUP_ID" ]; then
    print_error "GroupId cannot be empty!"
    exit 1
fi

if [ -z "$ARTIFACT_ID" ]; then
    print_error "ArtifactId cannot be empty!"
    exit 1
fi

if [ -z "$NEW_VERSION" ]; then
    print_error "Version cannot be empty!"
    exit 1
fi

# Escape dots in groupId for sed regex
ESCAPED_GROUP_ID=$(echo "$GROUP_ID" | sed 's/\./\\./g')

print_info "Updating dependency:"
echo "  - GroupId: $GROUP_ID"
echo "  - ArtifactId: $ARTIFACT_ID"
echo "  - New Version: $NEW_VERSION"

# Find all pom.xml files in top-level subdirectories (not including current directory)
print_info "Searching for pom.xml files in top-level subdirectories..."

# Find directories one level deep, then look for pom.xml in each
POM_FILES=$(find . -maxdepth 2 -mindepth 2 -name "pom.xml" -type f)

if [ -z "$POM_FILES" ]; then
    print_warning "No pom.xml files found in top-level subdirectories."
    exit 0
fi

print_info "Found pom.xml files:"
echo "$POM_FILES" | while read -r file; do
    echo "  - $file"
done

echo ""
UPDATED_COUNT=0

# Process each pom.xml file
echo "$POM_FILES" | while read -r POM_FILE; do
    if [ ! -f "$POM_FILE" ]; then
        continue
    fi
    
    print_info "Processing: $POM_FILE"
    
    # Create backup
    cp "$POM_FILE" "$POM_FILE.backup"
    
    # Check if the dependency exists in this pom file
    if grep -q "<groupId>$GROUP_ID</groupId>" "$POM_FILE" && grep -q "<artifactId>$ARTIFACT_ID</artifactId>" "$POM_FILE"; then
        
        # Create a temporary script for complex sed operation
        cat > /tmp/update_pom_sed.txt << EOF
/<dependency>/,/<\/dependency>/ {
    /<groupId>$ESCAPED_GROUP_ID<\/groupId>/ {
        :find_artifact
        n
        /<artifactId>$ARTIFACT_ID<\/artifactId>/ {
            :find_version
            n
            /<version>.*<\/version>/ {
                s/<version>.*<\/version>/<version>$NEW_VERSION<\/version>/
                b end_update
            }
            /<\/dependency>/ b end_update
            b find_version
        }
        /<\/dependency>/ b end_update
        b find_artifact
    }
}
:end_update
EOF
        
        # Apply the sed script
        sed -i.tmp -f /tmp/update_pom_sed.txt "$POM_FILE"
        
        # Clean up temporary files
        rm -f "$POM_FILE.tmp" /tmp/update_pom_sed.txt
        
        # Verify the change was made by checking for the exact dependency block
        if grep -A 10 -B 2 "<groupId>$GROUP_ID</groupId>" "$POM_FILE" | grep -A 5 "<artifactId>$ARTIFACT_ID</artifactId>" | grep -q "<version>$NEW_VERSION</version>"; then
            print_success "✓ Updated dependency in: $POM_FILE"
            UPDATED_COUNT=$((UPDATED_COUNT + 1))
            
            # Show the updated dependency block
            print_info "Updated dependency block:"
            grep -A 5 -B 1 "<groupId>$GROUP_ID</groupId>" "$POM_FILE" | grep -A 5 -B 1 "<artifactId>$ARTIFACT_ID</artifactId>" | sed 's/^/    /'
            echo ""
        else
            print_warning "⚠ Failed to update dependency in: $POM_FILE"
            print_warning "   The dependency structure might be different than expected"
            # Restore backup if update failed
            mv "$POM_FILE.backup" "$POM_FILE"
        fi
    else
        print_info "⏭ Dependency $GROUP_ID:$ARTIFACT_ID not found in: $POM_FILE (skipping)"
    fi
done

echo ""
print_info "═══════════════════════════════════════"
print_info "UPDATE SUMMARY"
print_info "═══════════════════════════════════════"

# Count final results (avoid subshell to preserve variables)
FINAL_UPDATED_COUNT=0
FINAL_TOTAL_COUNT=0
FINAL_FOUND_COUNT=0

# Use process substitution instead of pipe to avoid subshell
while read -r POM_FILE; do
    if [ ! -f "$POM_FILE" ]; then
        continue
    fi
    
    FINAL_TOTAL_COUNT=$((FINAL_TOTAL_COUNT + 1))
    
    # Check if dependency exists
    if grep -q "<groupId>$GROUP_ID</groupId>" "$POM_FILE" && grep -q "<artifactId>$ARTIFACT_ID</artifactId>" "$POM_FILE"; then
        FINAL_FOUND_COUNT=$((FINAL_FOUND_COUNT + 1))
        
        # Check if it was updated to the new version
        if grep -A 10 -B 2 "<groupId>$GROUP_ID</groupId>" "$POM_FILE" | grep -A 5 "<artifactId>$ARTIFACT_ID</artifactId>" | grep -q "<version>$NEW_VERSION</version>"; then
            FINAL_UPDATED_COUNT=$((FINAL_UPDATED_COUNT + 1))
        fi
    fi
done < <(echo "$POM_FILES")

echo "Dependency: $GROUP_ID:$ARTIFACT_ID"
echo "New Version: $NEW_VERSION"
echo "Files Processed: $(echo "$POM_FILES" | wc -l)"
echo "Dependencies Found: $FINAL_FOUND_COUNT"
echo "Successfully Updated: $FINAL_UPDATED_COUNT"

# Clean up backup files for successfully updated files
print_info "Cleaning up backup files..."
while read -r POM_FILE; do
    if [ -f "$POM_FILE.backup" ]; then
        # Check if update was successful
        if grep -A 10 -B 2 "<groupId>$GROUP_ID</groupId>" "$POM_FILE" | grep -A 5 "<artifactId>$ARTIFACT_ID</artifactId>" | grep -q "<version>$NEW_VERSION</version>"; then
            rm -f "$POM_FILE.backup"
        else
            print_warning "Backup preserved: $POM_FILE.backup (update failed or dependency not found)"
        fi
    fi
done < <(echo "$POM_FILES")

if [ "$FINAL_UPDATED_COUNT" -gt 0 ]; then
    print_success "🎉 Successfully updated $FINAL_UPDATED_COUNT dependency/dependencies!"
    print_info "💡 Tip: You can verify changes with: git diff"
else
    print_warning "No dependencies were updated. Please check:"
    echo "  - GroupId and ArtifactId are correct"
    echo "  - The dependency exists in your pom.xml files"
    echo "  - The dependency structure matches expected format"
fi

echo ""
print_info "Script execution completed!"

