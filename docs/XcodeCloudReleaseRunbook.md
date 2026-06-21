# Xcode Cloud Release Runbook

This repo builds three App Store platforms from three shared schemes:

| Platform | Xcode Cloud scheme | Notes |
| --- | --- | --- |
| iOS and iPadOS | `Noema` | `TARGETED_DEVICE_FAMILY = 1,2`; includes `NoemaEmbeddingActivity.appex`. |
| macOS | `NoemaMac` | Native macOS app target. |
| visionOS | `NoemaVisionOS` | Native visionOS app target. |

## Current release constraints

As of June 19, 2026, do not use Xcode 27 beta for a general App Store release. App Store Connect release notes list Xcode 27 beta builds for internal and external TestFlight testing, while Xcode 26.6 RC 2 builds are accepted for App Store upload. In Xcode Cloud, select the latest non-beta App Store-accepted Xcode image available to the workflow.

## Required repository cleanup before the first Cloud build

Xcode Cloud must be able to reproduce the checkout without local disk paths.

1. Commit the shared schemes:
   - `Noema.xcodeproj/xcshareddata/xcschemes/Noema.xcscheme`
   - `Noema.xcodeproj/xcshareddata/xcschemes/NoemaMac.xcscheme`
   - `Noema.xcodeproj/xcshareddata/xcschemes/NoemaVisionOS.xcscheme`
2. Make `External/NoemaLLamaServer` available through a network-accessible Git URL.
   - Preferred: update `.gitmodules` to the real GitHub repository URL.
   - Temporary: set `NOEMA_LLAMA_SERVER_REPOSITORY_URL` in each Xcode Cloud workflow environment.
3. Make sure the Xcode Cloud source-control account can read every private dependency, including `External/NoemaLLamaServer` if it stays private.
4. Keep `Package.resolved` committed so SwiftPM resolves the same dependency graph in Cloud.

The `ci_scripts/ci_post_clone.sh` script checks these conditions early and fails with a readable error before Xcode spends time resolving packages.

## App Store Connect setup

Use one multi-platform App Store Connect app record if all three targets intentionally share `arminproducts.Noema` as their bundle identifier. If you want separate app records per platform, split the bundle identifiers before creating release workflows.

Confirm these capabilities are enabled for the app identifier and profiles used by Xcode Cloud:

- CloudKit container `iCloud.arminproducts.Noema`
- Push Notifications
- App Attest
- Pass Type IDs for `pass.com.noemaai.noema.transport`
- Increased Memory Limit entitlement where Apple has approved it
- App Sandbox and network/audio capabilities for macOS

## Recommended workflows

Create three manual release workflows in Xcode Cloud, one per scheme. Keep them manual until the App Store metadata and signing are stable.

### Release iOS and iPadOS

- Product: `Noema.xcodeproj`
- Scheme: `Noema`
- Environment: latest non-beta App Store-accepted Xcode image
- Start condition: manual, release branch or tag only
- Actions:
  - Archive
  - Distribute to TestFlight first
  - Promote the processed build to App Store review from App Store Connect

### Release macOS

- Product: `Noema.xcodeproj`
- Scheme: `NoemaMac`
- Environment: latest non-beta App Store-accepted Xcode image
- Start condition: manual, release branch or tag only
- Actions:
  - Archive
  - Distribute to TestFlight first
  - Submit the macOS build from the macOS platform section in App Store Connect

### Release visionOS

- Product: `Noema.xcodeproj`
- Scheme: `NoemaVisionOS`
- Environment: latest non-beta App Store-accepted Xcode image
- Start condition: manual, release branch or tag only
- Actions:
  - Archive
  - Distribute to TestFlight first
  - Submit the visionOS build from the visionOS platform section in App Store Connect

## Versioning checklist

Before running the three release workflows:

1. Set the marketing version consistently. The app targets currently use `MARKETING_VERSION = 3`.
2. Set unique build numbers for each upload. Current project versions are `Noema = 1`, `NoemaVisionOS = 1`, `NoemaEmbeddingActivity = 1`, and `NoemaMac = 8`.
3. In Xcode Cloud, set the next build number high enough to avoid collisions with previously uploaded TestFlight/App Store builds.
4. Run the iOS workflow first because it also validates the widget extension.

## Local sanity commands

After accepting the Xcode license locally, these are the closest local checks to the Cloud archives:

```sh
xcodebuild build -project Noema.xcodeproj -scheme Noema -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
xcodebuild build -project Noema.xcodeproj -scheme NoemaMac -configuration Release -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
xcodebuild build -project Noema.xcodeproj -scheme NoemaVisionOS -configuration Release -destination 'generic/platform=visionOS' CODE_SIGNING_ALLOWED=NO
```

For local archives, omit `CODE_SIGNING_ALLOWED=NO` and use the same Apple Developer team as Xcode Cloud.
