# Home Assistant Add-ons by muewe

My collection of Home Assistant add-ons, built for my own setup and shared
in case they are useful to others.

[![Add repository to Home Assistant](https://my.home-assistant.io/badges/supervisor_add_addon_repository.svg)](https://my.home-assistant.io/redirect/supervisor_add_addon_repository/?repository_url=https%3A%2F%2Fgithub.com%2Fmuewe%2Fha-addons)

Click the button above to add this repository to your Home Assistant instance.
Afterwards, the add-ons below are available under
**Settings → Add-ons → Add-on Store**.

## Add-ons

### ebusd TypeSpec Compiler

<p align="left">
  <img src="ebusd-typespec-compiler/logo.svg" alt="ebusd TypeSpec Compiler logo" width="80">
</p>

Compiles the TypeSpec-based [ebusd-configuration](https://github.com/john30/ebusd-configuration)
repository (or any fork, branch, or GitHub pull request ref) and exports the
generated CSV files for [ebusd](https://github.com/e3d2/ebusd-2) to a
configurable path such as `/config/ebusd-configuration`.

Key points:

- Reproducible toolchain selection (`compatible` or `repository` mode)
- Multi-language export (`de`, `en`), replaced only after all languages
  compiled successfully
- Targeted single-file `.tsp` tests via an optional `entrypoint`
- Optional export of CSVs despite compiler errors, with explicit warnings
- Build provenance recorded per language in `.addon-build-info`

Runs manually, exits after its run — ideal for testing configuration PRs
before they are merged upstream.

[Documentation](ebusd-typespec-compiler/DOCS.md) · [Changelog](ebusd-typespec-compiler/CHANGELOG.md) · [Source repository](https://github.com/muewe/ha-ebusd-typespec-compiler)

## How this repository is maintained

Each add-on is developed in its own source repository; this repository only
contains the distribution metadata (`config.yaml`, changelog, documentation
and logos) that the Home Assistant Add-on Store displays. Users install the
prebuilt image from GitHub Container Registry — nothing is built on the
Home Assistant host.

The mapping between add-on directories and their source repositories is
defined in [addons.yaml](addons.yaml). The
[Add-on sync](.github/workflows/addon-sync.yml) workflow checks the source
repositories every six hours and can also be triggered manually. A release
in a source repository is a version bump in its `config.yaml`; when the sync
bot detects a new version, it copies the metadata files and opens a pull
request containing the new changelog. The add-on directories are fully
managed by the bot — manual edits are overwritten by the next sync.

### Adding a new add-on

1. Publish the add-on's image to `ghcr.io/<owner>/<image>` from its source
   repository and reference it with the `image` key in its `config.yaml`.
2. Add an entry to [addons.yaml](addons.yaml) mapping the add-on directory
   name to its source repository.
3. Run the *Add-on sync* workflow manually with the add-on name (or wait for
   the next scheduled run) to bootstrap the add-on directory and open the
   first sync pull request.

### Immediate sync on release (optional)

The scheduled run has a delay of up to six hours. A source repository can
trigger an immediate sync with a `repository_dispatch` event instead. This
requires a personal access token with write access to this repository,
stored as a secret (for example `ADDON_SYNC_TOKEN`) in the source repository:

```yaml
# .github/workflows/notify-store.yml in the source repository
name: Notify add-on store
on:
  push:
    branches: [main]
jobs:
  notify:
    runs-on: ubuntu-24.04
    steps:
      - run: gh api repos/muewe/ha-addons/dispatches -f event_type=addon-release
        env:
          GH_TOKEN: ${{ secrets.ADDON_SYNC_TOKEN }}
```

