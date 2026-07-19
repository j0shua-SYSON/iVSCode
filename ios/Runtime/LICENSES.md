# Runtime licensing and release inventory

This file is an engineering inventory, not legal advice and not a finished
`ThirdPartyNotices` file. Every release artifact must be rescanned from its
actual framework and Alpine package manifests.

| Component | Pinned source | Declared license | Release action |
| --- | --- | --- | --- |
| UTM | `utmapp/UTM` 4.7.5, commit `048ca7498ea3a374439149d51739d94c5300bcda` | Apache-2.0 | Preserve notices for any vendored launcher or FIFO-interface source. |
| QEMU | UTM `10.0.2-utm`, SHA-256 in `manifest.json` | GPL-2.0 | Publish corresponding source, UTM patches, build scripts, license, and required notices for the exact binary. Obtain distribution counsel. |
| QEMUKit | commit `589765abff27a8764d58b1a90999a204ac09881e` | Apache-2.0 | Preserve license and notices when linked or vendored. |
| Alpine Linux | 3.24.1 aarch64 minirootfs plus installed packages | Per-package licenses | Archive `packages.txt`, package metadata/licenses, repository URLs, image checksum, and source-offer material required by each package. |
| Code - OSS server payload | Built from this repository and bundled extensions | MIT plus per-component licenses | Ship this repository's license and generate notices/SBOM from the exact REH artifact. Do not infer every bundled extension's license from the root license. |

UTM's dependency build can produce LGPL/GPL libraries and optional static
GStreamer components. The headless collector intentionally ships only the
Mach-O closure reachable from `qemu-aarch64-softmmu.framework`, but reachability
is not a license classification. Retain `frameworks.txt` and `SHA256SUMS`, run a
license/SBOM scanner against that closure, and verify whether static code is
present in the QEMU framework.

Before App Store submission, counsel must assess both GPL compatibility with
store distribution terms and Apple's executable-code rules. The fact that UTM
SE itself is distributed through the App Store does not guarantee approval or
license compliance for a differently scoped IDE product.
