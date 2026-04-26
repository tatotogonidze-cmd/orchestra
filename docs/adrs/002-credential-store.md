# ADR 002: Encrypted file for credentials, OS keyring as a future enhancement

- **Status:** Accepted
- **Date:** 2026-04-21

## Context

Plugins need API keys (Tripo, Meshy, ElevenLabs, OpenAI, Anthropic, ...).
Keys must never be committed, never be logged, never leak into crash reports,
and ideally never live on disk in plaintext. They also must be accessible to
the app at runtime without the user re-pasting them on every launch.

We're shipping a Godot app to Windows/macOS/Linux desktops. Each OS has a
native keyring (DPAPI on Windows, Keychain on macOS, libsecret/SecretService
on Linux), but integrating cleanly across all three from GDScript requires
either a GDExtension or a per-OS shim, which is meaningful scope.

## Decision

**Phase 1 (this MVP):** store credentials in a single encrypted file via
Godot's built-in `FileAccess.open_encrypted_with_pass` (AES-256-CBC).

- File path: `user://credentials.enc` (outside the project directory, not
  committed).
- Schema: `{"plugins": {plugin_name: {key: value, ...}}}`.
- Unlocked with a **master password** the user enters at startup.
- In memory: unlocked contents live in a plain `Dictionary`; `lock()` zeroes
  both the cache and the held master password.

**Phase 2 (post-MVP):** optional OS keyring integration to eliminate the
master-password prompt on trusted machines, keeping the encrypted file as a
portable fallback.

## Consequences

- Zero native dependencies; ships today on all three OSes.
- Wrong password produces a clean "cannot decrypt" error, not silent
  corruption, because the Godot format validates on read.
- A compromised process can still read decrypted credentials from memory
  while the store is unlocked — that's the same threat model as the OS
  keyring case, so we're not worse off.
- The master password is a UX cost. We accept it for Phase 1.

## Alternatives considered

- **Plaintext `.env`.** Rejected: one stray `git add` leaks everything. The
  pre-commit hook (see `tools/check_plaintext_keys.py`) adds a second line
  of defense even so.
- **Immediate OS keyring integration.** Rejected for the MVP on scope
  grounds; tracked as a follow-up.
