# ShonenX — Release Builds

This repository is **not** a source fork of ShonenX. It is a release-only build harness: it builds and publishes ShonenX binaries with a small set of source overrides applied at build time.

## How it works

- Source code is fetched from [`roshancodespace/ShonenX`](https://github.com/roshancodespace/ShonenX) during the workflow run. The `source_ref` input (default `main`) selects the branch, tag, or commit to build.
- The only code override is [`lib/source_engine/providers/inbuilt_sources_provider.dart`](lib/source_engine/providers/inbuilt_sources_provider.dart), which registers the inbuilt anime sources provided by the `shonenx-sources` submodule.
- [`build.yaml`](.github/workflows/build.yaml) handles Android, Linux, Windows, macOS, and iOS builds, creates the release in **this** repository, and posts download links to Telegram.

## Usage

Run the **Build ShonenX** workflow from the Actions tab. Keep the configured secrets (`SUBMODULE_PAT`, Telegram bot token/chat ID, keystore and API credentials) in this repository's secrets — the workflow does not carry them in code.

## Important

Do not push ShonenX source code here. Keep changes limited to the provider override and the workflow. The upstream repository stays the single source of truth for the application code.
