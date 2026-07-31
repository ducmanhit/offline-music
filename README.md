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

## Build IPA unsigned bang GitHub Actions

Workflow hien tai khong can Apple certificate, provisioning profile, hay GitHub Secrets.
GitHub Actions se build app iOS bang `--no-codesign`, sau do dong goi thanh file `.ipa` unsigned.

File nay can duoc ky lai bang eSign, AltStore, Sideloadly, hoac cong cu signing khac truoc khi cai len iPhone.

Vao tab Actions tren GitHub, chon workflow `Build Unsigned iOS IPA`, bam `Run workflow`.
Sau khi build xong, tai artifact `CloudMusicOffline-unsigned-IPA`.
Trong artifact do co file `CloudMusicOffline-unsigned.ipa`.
