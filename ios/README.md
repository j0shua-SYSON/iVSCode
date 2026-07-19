# iVSCode for iOS and iPadOS

iVSCode is the on-device iPhone and iPad port of Code - OSS. It is built from
this repository and validated entirely with GitHub-hosted runners; no Apple
toolchain or dependency install is required on the Windows checkout machine.

## Architecture

The port has two runtime tiers behind one native shell:

1. **Instant workspace** starts the existing browser workbench in `WKWebView`.
   A loopback Swift server preserves a real HTTP origin for ES modules, workers,
   webviews, IndexedDB, and CSP. A built-in web extension maps
   `code-mobile:/workspace` to an app-container filesystem API.
2. **Full workspace** boots a bundled, interpreter-only ARM64 Linux image and
   runs the existing `vscode-reh-web-alpine-arm64-min` payload. The workbench
   then uses VS Code's standard remote filesystem, Node extension host, terminal,
   tasks, debugger, search, Git, and language-server paths.

The instant tier is the recovery and low-memory path. Full-workspace support is
the parity target; it deliberately reuses the REH protocol instead of replacing
VS Code subsystems with iOS-specific imitations.

## Repository layout

- `iVSCode/`: SwiftUI app, `WKWebView`, loopback server, and app-container store.
- `Shell/`: browser bootstrap served beside the production web bundle.
- `scripts/package-workbench.mjs`: deterministic staging of `vscode-web-min`.
- `Runtime/`: pinned Linux-emulation manifest and image tooling.
- `.github/workflows/ivscode-ios.yml`: web build, simulator/device compile, and
  unsigned IPA packaging on a GitHub-hosted macOS runner.

## CI build

The workflow performs the equivalent of:

```sh
npm ci
npm run gulp vscode-web-min
node ios/scripts/package-workbench.mjs --source ../vscode-web
xcodegen generate --spec ios/project.yml
xcodebuild -project ios/iVSCode.xcodeproj -scheme iVSCode \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Generated workbench files and Xcode output are ignored. Signed device and
TestFlight builds require an Apple team and signing secrets; the default CI path
produces an unsigned device bundle without storing credentials.

## Distribution boundary

The app bundles its runtime and curated extensions at build time. Downloaded
source stays visible and editable to the user. Installing opaque native
executables or extensions after review is intentionally outside the default
App Store profile.
