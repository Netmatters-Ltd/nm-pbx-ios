# TODO

## Branding

The app icon PNG at Linphone/Assets.xcassets/AppIcon.appiconset/1024x1024.png needs to be regenerated from the NMPBX X Isolated SVG. The SVG conversion tools weren't available, so you'll need to:

Open /brand/NMPBX_X_Isolated.svg
Export/convert it to a 1024x1024 PNG
Replace the existing 1024x1024.png in the AppIcon.appiconset

## iOS Push Notifications:

- Apple Developer account with push notification certificates
- APNS certificates (both standard remote notifications and VoIP push)
- Configure Flexisip server with apple=true and APNS certificates in /etc/flexisip/apn

## Android Push Notifications:

- Firebase project with FCM enabled
- Firebase project credentials (service account JSON for FCM V1 API)
- Configure Flexisip server with firebase=true and FCM credentials

## Flexisip Server Configuration:

The Flexisip SIP server supports both APNS and FCM natively and must be configured with credentials for both platforms to support both iOS and Android apps.
