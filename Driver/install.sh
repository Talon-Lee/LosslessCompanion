#!/bin/zsh
# 安裝虛擬裝置。需要管理員密碼；重啟 coreaudiod 時所有聲音會中斷幾秒，請先停止播放
set -euo pipefail
cd "${0:A:h}"
src=build/LosslessCompanionBridge.driver
dest=/Library/Audio/Plug-Ins/HAL/LosslessCompanionBridge.driver
[[ -d $src ]] || { echo "先執行 ./build.sh"; exit 1; }
sudo rm -rf $dest
sudo cp -R $src $dest
sudo chown -R root:wheel $dest
sudo killall -9 coreaudiod
echo "已安裝，等 coreaudiod 重新啟動後執行 ./probe"
