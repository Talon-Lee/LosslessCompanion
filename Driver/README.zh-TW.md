# LosslessCompanion Bridge（虛擬音訊裝置）

[English](README.md) | **繁體中文**

Hog 模式用的虛擬音訊裝置。Apple Music 輸出到這裡，LosslessCompanion 再從它的輸入端讀出樣本，轉送到獨佔中的實體 DAC。

- 原始碼來自 [BlackHole](https://github.com/ExistentialAudio/BlackHole)（GPL-3.0，版本見 `UPSTREAM`，原授權見 `LICENSE-BlackHole`）。
- 裝置名稱「LosslessCompanion Bridge」，UID `LosslessCompanionBridge_UID`，雙聲道 32-bit float，44.1 到 192 kHz。
- 不提供音量與靜音控制，系統音量滑桿無法縮放樣本；也不能當系統提示音的輸出。
- 從輸出端寫入的樣本原樣（memcpy）出現在輸入端，沒有任何運算。
- 時脈可以跟著實體 DAC 走：裝置有自訂屬性 `'lcfs'`（CFNumber），代表 Bridge 每個名目樣本要走多快，例如 0.9999862 就是慢 13.8 ppm。只在每個時脈週期（16384 個樣本）的邊界套用，時間戳記不會跳。範圍限制在 ±1000 ppm；App 超過 2 秒沒更新就退回系統時脈。控制迴路見 `../LosslessCompanion/Engine/StreamBridge.swift`。

## 使用

```bash
./build.sh                         # 建置並 ad-hoc 簽章到 build/
./install.sh                       # 需要管理員密碼；重啟 coreaudiod，所有聲音中斷幾秒
swiftc probe.swift -o probe        # 建置檢查工具
./probe                            # 回報是否載入、格式、取樣率、音量控制、預設輸出
./uninstall.sh                     # 移除並重啟 coreaudiod
```

安裝不會改變預設輸出。macOS 26 會載入 ad-hoc 簽章的外掛，不需要付費的開發者帳號。

`install.sh` 與 `uninstall.sh` 會用 `sudo`，請在「終端機」App 裡自己執行並輸入密碼。
