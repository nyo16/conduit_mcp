#!/bin/bash

# Release script for ConduitMCP
# Usage: ./scripts/release.sh

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Get version from mix.exs
VERSION=$(grep '@version' mix.exs | cut -d'"' -f2)

if [ -z "$VERSION" ]; then
  echo -e "${RED}Error: Could not determine version from mix.exs${NC}"
  exit 1
fi

echo -e "${GREEN}=== ConduitMCP Release Script ===${NC}"
echo -e "Version: ${YELLOW}v${VERSION}${NC}"
echo ""

# Check if working directory is clean
if [ -n "$(git status --porcelain)" ]; then
  echo -e "${RED}Error: Working directory is not clean${NC}"
  echo "Please commit or stash your changes first."
  git status --short
  exit 1
fi

# Check if on master branch
BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [ "$BRANCH" != "master" ] && [ "$BRANCH" != "main" ]; then
  echo -e "${YELLOW}Warning: Not on master/main branch (currently on: $BRANCH)${NC}"
  read -p "Continue anyway? (y/N) " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    exit 1
  fi
fi

# Check if tag already exists
if git rev-parse "v${VERSION}" >/dev/null 2>&1; then
  echo -e "${RED}Error: Tag v${VERSION} already exists${NC}"
  echo "Please bump the version in mix.exs first."
  exit 1
fi

echo -e "${GREEN}Step 1/5: Running tests...${NC}"
mix test || {
  echo -e "${RED}Tests failed! Aborting release.${NC}"
  exit 1
}

echo -e "${GREEN}Step 2/5: Building package...${NC}"
mix hex.build || {
  echo -e "${RED}Package build failed! Aborting release.${NC}"
  exit 1
}

echo -e "${GREEN}Step 3/5: Creating git tag v${VERSION}...${NC}"
git tag -a "v${VERSION}" -m "Release version ${VERSION}"

echo -e "${GREEN}Step 4/5: Pushing tag to origin...${NC}"
git push origin "v${VERSION}" || {
  echo -e "${RED}Failed to push tag! Rolling back...${NC}"
  git tag -d "v${VERSION}"
  exit 1
}

echo -e "${GREEN}Step 5/5: Publishing to Hex.pm...${NC}"
echo ""
echo -e "${YELLOW}About to publish conduit_mcp v${VERSION} to Hex.pm${NC}"
echo "This will make the package publicly available."
echo ""
read -p "Continue with hex publish? (y/N) " -n 1 -r
echo

if [[ $REPLY =~ ^[Yy]$ ]]; then
  mix hex.publish || {
    echo -e "${RED}Hex publish failed!${NC}"
    echo "Tag v${VERSION} was pushed but Hex publish failed."
    echo "You can retry with: mix hex.publish"
    exit 1
  }

  echo ""
  echo -e "${GREEN}=== Release Complete! ===${NC}"
  echo -e "Version ${YELLOW}v${VERSION}${NC} has been:"
  echo "  ✓ Tagged in git"
  echo "  ✓ Pushed to GitHub"
  echo "  ✓ Published to Hex.pm"
  echo ""
  echo "Package URL: https://hex.pm/packages/conduit_mcp"
  echo "Docs URL: https://hexdocs.pm/conduit_mcp/${VERSION}/"
else
  echo -e "${YELLOW}Hex publish cancelled.${NC}"
  echo "Tag v${VERSION} was created and pushed."
  echo "To publish later, run: mix hex.publish"
fi
