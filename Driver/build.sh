#!/bin/zsh
# 建置虛擬音訊裝置 LosslessCompanionBridge.driver，ad-hoc 簽章，輸出到 Driver/build
set -euo pipefail
cd "${0:A:h}"
out=build/LosslessCompanionBridge.driver
rm -rf build
mkdir -p $out/Contents/MacOS
cp Info.plist $out/Contents/Info.plist
defines=(
  -DkDriver_Name='"LosslessCompanionBridge"'
  -DkPlugIn_BundleID='"com.talonlee.LosslessCompanionHog.Bridge"'
  -DkPlugIn_Icon='""'
  -DkHas_Driver_Name_Format=0
  -DkDevice_Name='"LosslessCompanion Bridge"'
  -DkDevice2_Name='"LosslessCompanion Bridge Mirror"'
  -DkManufacturer_Name='"LosslessCompanion"'
  -DkNumber_Of_Channels=2
  -DkSampleRates='44100, 48000, 88200, 96000, 176400, 192000'
  # 不提供音量與靜音控制，系統音量滑桿就無法縮放樣本
  -DkEnableVolumeControl=0
  -DkExposeVolumeControls=0
  # 系統提示音不要被導到這裡
  -DkCanBeDefaultSystemDevice=0
)
clang -bundle -O2 -arch arm64 -arch x86_64 -mmacosx-version-min=12.0 \
  "${defines[@]}" -framework CoreAudio -framework CoreFoundation -framework Accelerate \
  -o $out/Contents/MacOS/LosslessCompanionBridge BlackHole.c
codesign --force --sign - --timestamp=none $out
codesign -dv $out 2>&1 | grep -E "Identifier|Signature"
echo "built $out"
