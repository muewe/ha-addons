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
