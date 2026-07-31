# Cloud Music Offline

App Flutter nghe nhac offline tren iPhone.

## Chuc nang

- Import file nhac tu app Files cua iPhone.
- Dung duoc Google Drive va OneDrive neu ban bat chung trong Files.
- Copy file vao bo nho rieng cua app de nghe offline.
- Player co play, pause, next, previous, shuffle, repeat one.
- Dieu khien bang AirPods qua iOS remote controls.
- Bat/tat AirPods controls trong Settings.
- Equalizer iOS native 5 bang tan so bang AVAudioUnitEQ.

## Dinh dang nen dung

- mp3
- m4a
- aac
- wav
- flac

## GitHub Secrets can thiet de build IPA

Tao cac secret nay trong GitHub repo: Settings -> Secrets and variables -> Actions.

- `IOS_BUNDLE_ID`: bundle id, vi du `com.tenban.cloudmusic`
- `APPLE_TEAM_ID`: Apple Team ID
- `IOS_PROFILE_NAME`: ten provisioning profile
- `IOS_EXPORT_METHOD`: `ad-hoc`, `development`, hoac `app-store`
- `IOS_P12_BASE64`: file certificate `.p12` da encode base64
- `IOS_P12_PASSWORD`: mat khau file `.p12`
- `IOS_PROVISIONING_PROFILE_BASE64`: file `.mobileprovision` da encode base64
- `IOS_KEYCHAIN_PASSWORD`: mat khau tam cho keychain tren GitHub Actions
- `IOS_CODE_SIGN_IDENTITY`: tuy chon, mac dinh la `Apple Distribution`

## Cach tao chuoi base64

Tren macOS:

```bash
base64 -i certificate.p12 | pbcopy
base64 -i profile.mobileprovision | pbcopy
```

Dan ket qua vao GitHub Secrets tuong ung.

Tren Windows PowerShell:

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("certificate.p12")) | Set-Clipboard
[Convert]::ToBase64String([IO.File]::ReadAllBytes("profile.mobileprovision")) | Set-Clipboard
```

## Build IPA

Vao tab Actions tren GitHub, chon workflow `Build iOS IPA`, bam `Run workflow`.
Sau khi build xong, tai file `.ipa` trong phan Artifacts.
