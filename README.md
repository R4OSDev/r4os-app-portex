# Portex

Portex is the native R4OS software center. It consumes the R4OS Server
software catalog and uses the shared installation/update owners.

The first development step provides typed application, runtime-library and
kernel packages, lossless server IDs, catalog-to-installation bindings and
generation-bound UI job observations. Server access and the Prisma GUI are
subsequent roadmap steps. The app is not shipped by normal images yet.

Build with `./Build.sh` on Linux or `Build.bat` on Windows. Both delegate to
the selected SDK. Run the owner tests with the same starter and `test`.
`Settings.R4S` contains locations, never an independent tool/build profile.

Installed components remain authoritative in `MODULES.JSON`. Portex's binding
metadata cannot establish installation without a matching actual component.
No runtime dependency or compatibility prechecks are added in this version.

Original R4OS code is licensed under Apache-2.0. See `LICENSE` and `NOTICE`.
