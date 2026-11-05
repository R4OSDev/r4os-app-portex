# Portex

Portex is the native R4OS software center. It consumes the R4OS Server
software catalog and uses the shared installation/update owners.

The native Prisma view provides Discover, My Software and Updates, all three
package kinds, categories, search, alphabetical cards and package details.
Catalog, bindings and installed inventory load on a joined worker. Stale,
unavailable, unverified and local-only states stay distinct. New destinations
preserve the original filename; existing installations retain their path.
R4X installation and targeted adoption use the SDK's existing journal and
inventory transaction owner. A durable request also binds the actual path,
version, original bytes and owned R4LNK. Interrupted work can be resumed;
opening the store only observes the real files and known Desktop bindings.
Libraries and kernel assets use the same owner's durable restart batch.
The SDK derives and binds the installed BOOT plan; a second explicit action
authorizes activation and reboot. Reopening only observes staged work.
Installed catalog apps, libraries and kernel are checked at startup and every
five minutes while the window is open. Only explicit single/all-update actions
create a durable frozen selection. Per-package outcomes survive closing and
reboot; completed items are skipped on retry. Restart artifacts pause remaining
work until explicit activation and continuation. Each asset retains the existing
transaction boundary; several system artifacts can need several reboots.
Uninstall follows its later owner adapter.
Original-asset downloads run on a joined
worker with an immutable catalog binding, durable partials, checked Range /
If-Range continuation, a shared three-retry budget, cancellation and visible
byte/percentage/rate/error status. Small transport fragments share a bounded
64-KB write buffer. The finite whole-request deadline scales with asset size.
Only a complete size/SHA-256 readback yields
ready; that receipt does not install a package. Software access reuses R4SRV
registration and verified HTTPS, with an ETag-bound durable catalog cache.
Portex ships in the official Slim, Full and Test images. From SSH, use
`DESKRUN` to start its GUI in the existing Desktop.

Build with `./Build.sh` on Linux or `Build.bat` on Windows. Both delegate to
the selected SDK. Run the owner tests with the same starter and `test`.
`Settings.R4S` contains locations, never an independent tool/build profile.

Installed components remain authoritative in `MODULES.JSON`. Portex's binding
metadata cannot establish installation without a matching actual component.
No runtime dependency or compatibility prechecks are added in this version.

Unchanged pointer hits and ineffective keys/scrolling leave the committed frame
untouched. Hover/press and visible worker progress use independent complete
replacement frames with client damage; layout changes draw the full client.
Queued input is dispatched in order, with a bound and a layout rebuild before
hit-testing a changed view. Workers retain cancellation and actual join ownership.

The accepted visual reference is preserved in `Design/Prisma.html`. Native
rendering uses the public SDK controls and optional manifest title colors;
the Desktop draws the outer frame. Current system fonts remain bitmap fonts.

Original R4OS code is licensed under Apache-2.0. See `LICENSE` and `NOTICE`.
