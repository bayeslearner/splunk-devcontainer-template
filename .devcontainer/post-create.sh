#!/bin/bash
set -e

echo "=== Splunk Dev: post-create setup ==="

# ── PATH setup ───────────────────────────────────────────────────────
mkdir -p "$HOME/.local/bin"
if ! grep -q '.local/bin' "$HOME/.bashrc" 2>/dev/null; then
  # shellcheck disable=SC2016
  echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
fi
export PATH="$HOME/.local/bin:$PATH"

# ── System tools ─────────────────────────────────────────────────────
echo "Installing system tools (expect, libmagic)..."
sudo apt-get update -qq && sudo apt-get install -y -qq expect libmagic1 >/dev/null 2>&1

# ── uv (fast Python package manager + version manager) ─────────────
echo "Installing uv..."
curl -LsSf https://astral.sh/uv/install.sh | sh 2>/dev/null
export PATH="$HOME/.local/bin:$PATH"

# ── Python dev tools ─────────────────────────────────────────────────
echo "Installing Python tools (appinspect, ruff, pytest, ucc-gen, codegen)..."
pip install --user --quiet splunk-appinspect ruff pytest splunk-add-on-ucc-framework datamodel-code-generator 2>/dev/null

# ── Create .env from example if missing ──────────────────────────────
if [ ! -f /workspace/.env ] && [ -f /workspace/.env.example ]; then
  cp /workspace/.env.example /workspace/.env
  echo ".env created from .env.example"
fi

# ── Ensure directory structure ───────────────────────────────────────
mkdir -p /workspace/infra/config
mkdir -p /workspace/infra/deps
mkdir -p /workspace/apps
mkdir -p /workspace/output

# ── Claude Code memory persistence ──────────────────────────────────
# Symlink Claude memory into the project so it survives container rebuilds
if [ -d /workspace/.claude/memory ]; then
  mkdir -p "$HOME/.claude/projects/-workspace"
  ln -sfn /workspace/.claude/memory "$HOME/.claude/projects/-workspace/memory"
  echo "Claude Code memory linked to project directory"
fi

# ── Build Splunk image ────────────────────────────────────────────────
echo "Building Splunk dev image (first time only)..."
task dev:build-image 2>&1 | tail -5 || true

echo "=== Setup complete. Run 'task dev:up' to start Splunk. ==="
