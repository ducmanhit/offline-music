# Cloud Music Offline

App nghe nhac offline cho iPhone, build bang GitHub Actions thanh file IPA unsigned de ky bang eSign.

## Chuc nang v3

- Giao dien lay cam hung tu app mau: Trang chu, Bit-Perfect, Thu vien, Tham dinh/Cai dat.
- Trang chu co search, lich su nghe, WiFi transfer, bo chinh am, Wrapped, mix hang ngay, nghe gan day.
- Thu vien co search, tab Bai hat/Playlist/Thu muc/Nghe si/Album, sap xep, play all, shuffle, alphabet rail.
- Player toan man hinh co anh bia, metadata chip, waveform, shuffle, repeat, yeu thich, AirPlay hint, sleep timer.
- Bit-Perfect co Purist mode va duong tin hieu.
- Cai dat co nhom xo xuong: phat nhac, thong bao, giao dien, WiFi, Wrapped, bo nho, ngon ngu, tai khoan, gioi thieu.
- Import nhieu file nhac tu Files.
- Lay nhac tu Google Drive hoac OneDrive thong qua app Files cua iPhone.
- Truyen nhac tu may tinh qua WiFi bang server HTTP trong app.
- Copy nhac vao bo nho rieng cua app de nghe offline.
- Phat nhac bang `just_audio`, on dinh hon native bridge tu viet.
- Ho tro lock screen va AirPods controls qua `just_audio_background`.
- Danh dau yeu thich, doi ten bai hat, chon anh bia tu Files, xoa file offline.
- Sleep timer 15/30/45/60 phut.
- Sound profile UI voi cac preset Flat, Bass, Vocal, Bright, Night.

## Build IPA unsigned

Workflow khong can Apple certificate, provisioning profile, hay GitHub Secrets.

Vao GitHub:

```text
Actions -> Build Unsigned iOS IPA -> Run workflow
```

Sau khi build xanh, tai artifact:

```text
CloudMusicOffline-unsigned-IPA
```

Giai nen artifact se co:

```text
CloudMusicOffline-unsigned.ipa
```

Dung file nay dua vao eSign de ky va cai len iPhone.

## Luu y

File IPA unsigned chua cai truc tiep len iPhone duoc. Can ky lai bang eSign, Sideloadly, AltStore, hoac cong cu signing tuong tu.
