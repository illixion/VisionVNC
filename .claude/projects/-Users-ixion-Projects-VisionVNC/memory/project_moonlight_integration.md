---
name: Moonlight game streaming integration
description: Plan to add Moonlight/Sunshine game streaming to VisionVNC by porting moonlight-common-c protocol library, not by recompiling the iOS app
type: project
---

Decision made 2026-04-03: integrate Moonlight game streaming into VisionVNC by porting the moonlight-common-c C protocol library as a local SPM package, rather than trying to compile the Moonlight iOS app for visionOS.

**Why:** The Moonlight iOS app is UIKit/Storyboard/Objective-C with no visionOS support. Recompiling it would require rewriting ~70% of the app. VisionVNC already has a working SwiftUI multi-window architecture, CADisplayLink rendering, and gesture infrastructure that can be reused.

**How to apply:** Full implementation plan is in MOONLIGHT_PLAN.md at the repo root. Reference repos (moonlight-ios, moonlight-qt, Sunshine) are in repos/ (gitignored). The moonlight-qt C++ codebase is the best reference for the Swift bridge implementation. User streams games from a PopOS 24 PC running Sunshine server.
