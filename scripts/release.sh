#!/bin/bash

# Release script for ConduitMCP
# Usage: ./scripts/release.sh
#
# Publishing happens in CI. HEX_API_KEY must be a secret of the
# `hex-release` GitHub environment (not a repository secret), and that
# environment must be restricted to `v*` tags with required reviewers.

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Get version from mix.exs: the `@version "..."` attribute line only (other
# lines mention `@version` too).
VERSION=$(grep -E '^[[:space:]]*@version "' mix.exs | head -n 1 | cut -d'"' -f2)

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

echo -e "${GREEN}Step 1/4: Running tests...${NC}"
mix test || {
  echo -e "${RED}Tests failed! Aborting release.${NC}"
  exit 1
}

echo -e "${GREEN}Step 2/4: Building package...${NC}"
mix hex.build || {
  echo -e "${RED}Package build failed! Aborting release.${NC}"
  exit 1
}

echo -e "${GREEN}Step 3/4: Creating git tag v${VERSION}...${NC}"
git tag -a "v${VERSION}" -m "Release version ${VERSION}"

echo -e "${GREEN}Step 4/4: Pushing tag to origin...${NC}"
git push origin "v${VERSION}" || {
  echo -e "${RED}Failed to push tag! Rolling back...${NC}"
  git tag -d "v${VERSION}"
  exit 1
}

# The tag push is the only publish path: CI's `publish` job publishes to
# Hex once every other job (tests, Dialyzer, audits, the bare-consumer
# check) has passed for this tag. Publishing from here too would skip those
# gates.
REPO_URL=$(git remote get-url origin | sed -E 's#^git@github\.com:#https://github.com/#; s#^(https?://)[^@/]*@#\1#; s#\.git$##')

echo ""
echo -e "${GREEN}=== Tag v${VERSION} pushed ===${NC}"
echo "CI publishes to Hex.pm once every job passes for the tag:"
echo "  ${REPO_URL}/actions"
echo ""
echo "Package URL: https://hex.pm/packages/conduit_mcp"
echo "Docs URL: https://hexdocs.pm/conduit_mcp/${VERSION}/"
