# Branding Plan

## Overview
This plan outlines the changes required to rebrand the linphone-iphone app to NMPBX, a product by Netmatters. The rebranding involves updates to app naming, visual identity (colors, fonts, icons), localization strings, and configuration files.

---

## 1. App Identity & Configuration

### 1.1 App Display Name
**Files to update:**
- [LinphoneApp.xcodeproj/project.pbxproj](LinphoneApp.xcodeproj/project.pbxproj)
  - Change `INFOPLIST_KEY_CFBundleDisplayName` from "Linphone" to "NMPBX" for the main app target
  - Update display names for extensions: msgNotificationService, linphoneExtension, intentsExtension

### 1.2 Bundle Identifiers
**Files to update:**
- [LinphoneApp.xcodeproj/project.pbxproj](LinphoneApp.xcodeproj/project.pbxproj)
  - Change `PRODUCT_BUNDLE_IDENTIFIER` from `org.linphone.phone` to a Netmatters-specific identifier (e.g., `uk.co.netmatters.nmpbx`)
  - Update bundle identifiers for all extensions accordingly
  - Update URL scheme identifiers

### 1.3 App Group Identifiers
**Files to update:**
- [Linphone/Linphone.entitlements](Linphone/Linphone.entitlements)
- [linphoneExtension/linphoneExtension.entitlements](linphoneExtension/linphoneExtension.entitlements)
- [msgNotificationService/msgNotificationService.entitlements](msgNotificationService/msgNotificationService.entitlements)
- [Linphone/Utils/Extensions/ConfigExtension.swift](Linphone/Utils/Extensions/ConfigExtension.swift)
  - Change `group.org.linphone.phone.*` to match new bundle identifier structure

### 1.4 URL Schemes
**Files to update:**
- [Linphone/Info.plist](Linphone/Info.plist)
  - Update URL schemes from `linphone-mention`, `linphone-message`, `linphone-config` to NMPBX equivalents
- [linphoneExtension/ShareViewController.swift](linphoneExtension/ShareViewController.swift)
  - Update URL scheme construction

### 1.5 Activity Types
**Files to update:**
- [intentsExtension/IntentHandler.swift](intentsExtension/IntentHandler.swift)
  - Change activity type from `org.linphone.startCall` to NMPBX equivalent

---

## 2. Visual Identity

### 2.1 App Icons
**Directory:** [Linphone/Assets.xcassets/AppIcon.appiconset/](Linphone/Assets.xcassets/AppIcon.appiconset/)
- Replace all app icons with NMPBX_X_Isolated variants
- For icons 26px or smaller, use `NMPBX_X_Isolated_Small.svg`
- For larger icons, use `NMPBX_X_Isolated.svg`
- Convert SVG files from [brand/](brand/) directory to required PNG sizes and resolutions

### 2.2 Launch/Splash Screen Images
**Files to update:**
- [Linphone/Assets.xcassets/linphone.imageset/](Linphone/Assets.xcassets/linphone.imageset/)
  - Replace with NMPBX logo (use `NMPBX_NMPBX_Main_Logo.svg` or `NMPBX_NMPBX_Black_Logo.svg` for light backgrounds)
- [Linphone/SplashScreen.swift](Linphone/SplashScreen.swift)
  - Update Image reference and potentially adjust background color

### 2.3 In-App Branding Images
**Files to update:**
- [Linphone/Assets.xcassets/app-store-logo.imageset/](Linphone/Assets.xcassets/app-store-logo.imageset/)
  - Replace with NMPBX logo variants
- [Linphone/Assets.xcassets/illus-belledonne.imageset/](Linphone/Assets.xcassets/illus-belledonne.imageset/)
  - Replace or remove Belledonne Communications branding with Netmatters branding

### 2.4 CallKit Icon
**Files to update:**
- [Linphone/TelecomManager/ProviderDelegate.swift](Linphone/TelecomManager/ProviderDelegate.swift)
  - Update icon template image from "linphone" to new NMPBX icon asset

---

## 3. Color Scheme

### 3.1 Theme Manager
**Files to update:**
- [Linphone/Utils/ThemeManager.swift](Linphone/Utils/ThemeManager.swift)
  - Update default theme from "orange" to new NMPBX branding
  - Create NMPBX theme with:
    - Primary: #25af4b (green)
    - Secondary: #0e2826 (dark teal)
    - Gradient support: #25af4b to #a4cd3a
  - Consider mapping existing theme colors to NMPBX brand colors
  
### 3.2 Hardcoded Colors
**Files to review:** Throughout [Linphone/UI/](Linphone/UI/)
- Search for hardcoded color values like `Color.orangeMain500`, `Color.orangeMain100`, etc.
- Update to use NMPBX green theme colors
- Ensure proper contrast with brand colors (black text on #25af4b, white text on #0e2826)

---

## 4. Typography

### 4.1 Font Files
**Actions required:**
- Copy Poppins font files from [brand/Poppins/](brand/Poppins/) to [Linphone/Fonts/](Linphone/Fonts/)
- Required weights:
  - Poppins-Bold.ttf (for main titles)
  - Poppins-Medium.ttf (for sub-titles)
  - Poppins-Light.ttf (for body text)
  - Additional weights as needed: Regular, SemiBold, ExtraBold

### 4.2 Font Registration
**Files to update:**
- [LinphoneApp.xcodeproj/project.pbxproj](LinphoneApp.xcodeproj/project.pbxproj)
  - Update font file references from NotoSans-*.ttf to Poppins-*.ttf
  - Ensure fonts are included in "Copy Bundle Resources" build phase
- [Linphone/Info.plist](Linphone/Info.plist)
  - Update `UIAppFonts` array to reference Poppins font files

### 4.3 Font Usage
**Files to review:** Search throughout codebase for font references
- Look for ".font(.custom(...))" or similar SwiftUI font declarations
- Update font family names from "NotoSans" to "Poppins"
- Maintain weight mappings: Bold → Poppins-Bold, Medium → Poppins-Medium, Light → Poppins-Light

---

## 5. Localization & Text Content

### 5.1 App Name References
**Files to update:**
- All [Linphone/Localizable/*/Localizable.strings](Linphone/Localizable/) files (17 languages)
  - Replace references to "Linphone" with "NMPBX"
  - Key areas: app name mentions, permission descriptions, onboarding text
- [Linphone/Utils/Extensions/BundleExtenion.swift](Linphone/Utils/Extensions/BundleExtenion.swift)
  - Update fallback app name from "Linphone" to "NMPBX"

### 5.2 URLs and Links
**Files to review:** All localization files
- Replace linphone.org URLs with Netmatters URLs:
  - Website: https://www.netmatters.co.uk/
  - Contact: https://www.netmatters.co.uk/contact-us
- Update SIP service references (e.g., `sip.linphone.org`) to appropriate NMPBX service URLs
- Update subscription/account creation links

### 5.3 Company Information
**Files to update:**
- Update support email addresses (currently `linphone-iphone@belledonne-communications.com`)
- Add Netmatters contact information where appropriate:
  - Phone: 01603 51 52 83
  - Address: Unit 15, Penfold Drive, Gateway 11 Business Park, Wymondham, Norfolk, NR18 0WZ

### 5.4 Feature Descriptions
**Files to review:** Localization files
- Update permission descriptions to use "NMPBX" instead of "%@" placeholder where brand name is referenced
- Review and update all user-facing strings that mention features or capabilities

---

## 6. Code References

### 6.1 Comments and Documentation
**Files to review:** All .swift files
- Update copyright headers (currently reference Belledonne Communications SARL)
- Update project description comments (currently "part of linphone-iphone" or "part of Linphone")
- Consider whether to retain original attributions per license requirements

### 6.2 Variable and Constant Names
**Files to review:**
- [msgNotificationService/NotificationService.swift](msgNotificationService/NotificationService.swift)
  - Variable like `LINPHONE_DUMMY_SUBJECT` may need renaming
- Search for "linphone" or "Linphone" in variable/constant names throughout codebase
- Update to NMPBX equivalents where appropriate for consistency

### 6.3 Notification Names
**Files to update:**
- [Linphone/TelecomManager/ProviderDelegate.swift](Linphone/TelecomManager/ProviderDelegate.swift) and [TelecomManager.swift](Linphone/TelecomManager/TelecomManager.swift)
  - Notification name "LinphoneCallUpdate" should be renamed to NMPBX equivalent

### 6.4 Service URLs
**Files to update:**
- [Linphone/TelecomManager/TelecomManager.swift](Linphone/TelecomManager/TelecomManager.swift)
  - Update hardcoded Linphone service URLs (e.g., `sip.linphone.org`, `conference-focus@sip.linphone.org`)
  - Replace with NMPBX service infrastructure URLs

---

## 7. Project Structure

### 7.1 Directory Renaming
**Consider renaming:**
- Main app folder from "Linphone" to "NMPBX" (may impact many file references)
- Weigh benefits vs. effort/risk

### 7.2 Target Names
**Files to update:**
- [LinphoneApp.xcodeproj/project.pbxproj](LinphoneApp.xcodeproj/project.pbxproj)
  - Consider renaming "LinphoneApp.xcodeproj" to "NMPBXApp.xcodeproj"
  - Update target names if desired

---

## 8. External Resources

### 8.1 README and Documentation
**Files to update:**
- [README.md](README.md)
  - Replace all Linphone references with NMPBX
  - Update company information from Belledonne Communications to Netmatters
  - Update links and contact information
  - Update TestFlight links if applicable
  - Revise licensing section per Netmatters' requirements

### 8.2 Contributing Guidelines
**Files to update:**
- [CONTRIBUTING.md](CONTRIBUTING.md)
  - Update project name and references
  - Update contact information

### 8.3 Changelog
**Files to update:**
- [CHANGELOG.md](CHANGELOG.md)
  - Add entry documenting the rebrand to NMPBX
  - Attribute to Netmatters

---

## 9. Build Configuration

### 9.1 Firebase/Google Services
**Files to update:**
- [GoogleService-Info.plist](GoogleService-Info.plist) (root)
- [msgNotificationService/GoogleService-Info.plist](msgNotificationService/GoogleService-Info.plist)
  - Update with NMPBX Firebase project configuration
  - Ensure bundle identifiers match new naming

### 9.2 Provisioning and Signing
**Actions required:**
- Create new App IDs in Apple Developer Portal with NMPBX bundle identifiers
- Update provisioning profiles
- Update app group entitlements in Apple Developer Portal
- Verify signing certificates

---

## 10. Testing & Validation

### 10.1 Functional Testing
- Test URL scheme handling with new schemes
- Verify app groups work with new identifiers
- Test push notifications
- Verify CallKit integration with new icons
- Test share extension functionality

### 10.2 Visual Testing
- Verify all icons display correctly at various sizes
- Check splash screen appearance
- Validate theme colors throughout the app
- Confirm font rendering (especially weights: Bold, Medium, Light)
- Test on both light and dark mode

### 10.3 Localization Testing
- Verify all 17 language files have updated strings
- Check for any remaining "Linphone" references
- Validate translated strings still make sense with NMPBX branding

---

## 11. Asset Conversion Tasks

### 11.1 SVG to PNG Conversion
**Required conversions from brand/ directory:**
- Convert `NMPBX_X_Isolated.svg` to all required AppIcon sizes
- Convert `NMPBX_X_Isolated_Small.svg` for small icons
- Convert `NMPBX_NMPBX_Main_Logo.svg` for splash screen
- Consider creating dark/light variants for adaptive icons

### 11.2 Icon Specifications
**iOS App Icon sizes needed:**
- 1024x1024 (App Store)
- 180x180 (iPhone @3x)
- 120x120 (iPhone @2x)
- 167x167 (iPad Pro)
- 152x152 (iPad)
- Additional sizes per Apple's current requirements

---

## 12. Priority & Phasing

### Phase 1 (Critical - App Identity)
1. Bundle identifiers and entitlements
2. App display name
3. App icons
4. Splash screen logo

### Phase 2 (High Priority - Visual Identity)
1. Color theme implementation
2. Font replacement
3. Primary brand images

### Phase 3 (Medium Priority - Content)
1. Localization strings
2. URLs and service endpoints
3. README and documentation

### Phase 4 (Low Priority - Code Quality)
1. Code comments and headers
2. Variable naming
3. Internal reference cleanup

---

## Notes

- **Licensing:** Original app is GPL-3.0. Ensure compliance when rebranding.
- **Attribution:** Consider keeping original Belledonne Communications attributions where required by license.
- **SDK Dependency:** App uses linphone-sdk-swift-ios. Verify that rebranding doesn't conflict with SDK behavior or requirements.
- **Backward Compatibility:** Consider migration path for existing users if app is already published under Linphone branding.

