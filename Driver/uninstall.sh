#!/bin/zsh
# 移除虛擬裝置並重啟 coreaudiod
set -euo pipefail
sudo rm -rf /Library/Audio/Plug-Ins/HAL/LosslessCompanionBridge.driver
sudo killall -9 coreaudiod
echo "已移除"
