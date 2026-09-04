# AGENTS.md

This file provides guidance to coding agents when working with this repository.

## Rule of the Responses

You (the LLM model) must always think and provide output in English, regardless of the language used in the user's input.

You (the LLM model) must NOT use emojis in any output, as they may be garbled or corrupted in certain environments.

## Project Overview

This is `gateway-sdk-kit`, a dependency-free Swift package that holds the gateway-independent half of the tacogips gateway client SDKs (wrike-gateway, google-analytics-gateway, apple-gateway, gmail-gateway, google-documents-gateway): the neutral schema catalog model, SDL printing, regex schema search, the operation-to-GraphQL-document builder, the argv builder for command-style gateways, and the lexer-aware variable inliner.

It must never contain gateway-specific code or credentials handling, and it must never gain a dependency.

## Development Environment

- Language: Swift 6 (`swiftLanguageModes: [.v6]`), macOS 14+, Linux-clean (Foundation only)
- Package manager: Swift Package Manager
- Environment manager: mise (`mise install`)

## Common Commands

```bash
mise run build
mise run test
mise run lint
```

## Swift Code Development

When implementing, refactoring, reviewing, or maintaining Swift code, use the Swift coding skill at `.codex/skills/swift-coding-agent/SKILL.md`.

Important defaults:

- Inspect `Package.swift`, nearby source, tests, and existing conventions before editing.
- Keep Swift files under 1000 lines. Split long files by meaningful responsibility.
- Run `swiftlint` after Swift edits when available.
- Run the narrowest relevant `swift test` or `swift build` command, then broaden when shared behavior changed.

## Git Commit Policy

When a user asks to commit changes, automatically stage and commit the changes without requiring confirmation.

Do not add AI tool attribution or co-authorship information to commit messages.

## Design Documentation

Place design documents under `design-docs/`, implementation plans under `impl-plans/`, and user decisions/questions under `design-docs/user-qa/`.
