# PixelRoll
PixelRoll is a native macOS photo library and RAW editor inspired by Apple Aperture. Featuring Finder-based organization, non-destructive editing, and a streamlined photographic workflow.


## Public beta

PixelRoll 0.16 is available as a public beta. Download **PixelRoll-0.16.dmg** from the [0.16 release](https://github.com/BillsWorkbench/PixelRoll/releases/tag/v0.16).

The initial beta will use the free distribution route: it will not have an Apple Developer ID signature or Apple notarization. macOS may block the first launch until you approve this specific app.

## Requirements

- Initial beta target: an Apple silicon Mac (M1 or later), running macOS 15 or later. Check the release notes for the tested requirements of each download.
- No Xcode, paid Apple Developer membership, or subscription is needed to use the downloaded app.
- RAW support depends on the camera format and the RAW decoders supplied by your macOS version.

## Install PixelRoll

1. Visit [Releases](https://github.com/BillsWorkbench/PixelRoll/releases) and select the beta you want to try.
2. Under **Assets**, download the PixelRoll **.dmg** installer. GitHub's automatically generated source-code archives are not the installer.
3. Open the disk image and drag **PixelRoll** into **Applications**.
4. Eject the disk image, then launch PixelRoll from Applications.
5. If macOS blocks the launch because the developer cannot be verified or Apple cannot check the app, follow the first-launch steps below.
6. In PixelRoll, choose your top photo folder. This lets the app browse its subfolders and save edits beside the photos.

### Approve the first launch

Only approve a copy downloaded from this repository's Releases page that you trust. The beta has not been checked by Apple's notarization service.

1. Attempt to launch PixelRoll once, then dismiss the blocked-app notice.
2. In **System Settings**, select **Privacy & Security** and find the notice about PixelRoll under Security.
3. Use **Open Anyway** for PixelRoll, authenticate if requested, and confirm the launch.

macOS records an exception for that app. A replacement build may require approval again. This uses an exception for PixelRoll; you do not need to disable Gatekeeper or run Terminal commands.

See [Apple's explanation of opening apps from unidentified developers](https://support.apple.com/en-us/102445). If the alert says the app is damaged or will harm your computer, stop and report the exact message instead of following these approval steps. A managed work Mac may require help from its administrator.

## Your photos and edits

PixelRoll saves ratings, keywords, captions and adjustments in **.pixelroll sidecar files beside the photos**. Original photo files are not rewritten. Keep the photos and sidecars together when moving or backing up a library. Try the beta with copies of photos first.

## Update PixelRoll

Finish saving your edits and quit PixelRoll. Download the newer installer, then replace the app in Applications. Keep your photo folders and sidecars. Read the release notes for any migration instructions, and follow the first-launch steps again if macOS requests approval.

## Report a problem

Open a [GitHub issue](https://github.com/BillsWorkbench/PixelRoll/issues) with the PixelRoll version, macOS version, Mac model, photo format/camera model, and steps to reproduce the problem. Include the exact error message or a screenshot when useful. Avoid posting private photos or personal metadata.


## 0.16 beta notes

Publish exports JPEG, TIFF and HEIF with current adjustments and crops, output sizing, color profiles, duplicate handling and batch cancellation. TIFF output is currently 8-bit. Printing is not enabled yet.

Known issues: noise reduction needs further improvement. An accessibility-driven SwiftUI button activation crashed during automated testing; normal mouse-driven export passed. Accessibility activation needs further investigation.

Validation: 62 automated checks passed, including Nikon NEF and Leica DNG exports.
