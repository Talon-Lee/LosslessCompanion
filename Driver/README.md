# LosslessCompanion Bridge (virtual audio device)

**English** | [繁體中文](README.zh-TW.md)

The virtual audio device used by Hog mode. Apple Music plays into it, and LosslessCompanion reads the samples from its input side and passes them to the physical DAC it holds exclusively.

- Based on [BlackHole](https://github.com/ExistentialAudio/BlackHole) (GPL-3.0; version in `UPSTREAM`, original license in `LICENSE-BlackHole`).
- Device name "LosslessCompanion Bridge", UID `LosslessCompanionBridge_UID`, 2-channel 32-bit float, 44.1 to 192 kHz.
- No volume or mute controls, so the system volume slider cannot scale the samples. It cannot be the alert sound device either.
- Samples written to the output appear unchanged (memcpy) on the input, with no processing.
- Its clock can follow the physical DAC: the device has a custom property `'lcfs'` (CFNumber) that sets how fast the Bridge runs per nominal sample; 0.9999862, for example, is 13.8 ppm slow. It is applied only at clock period boundaries (16384 samples), so timestamps never jump. The range is limited to ±1000 ppm, and if the app stops updating it for 2 seconds the clock falls back to host time. The control loop is in `../LosslessCompanion/Engine/StreamBridge.swift`.

## Usage

```bash
./build.sh                         # build and sign ad hoc into build/
./install.sh                       # needs your admin password; restarts coreaudiod, so all audio stops for a few seconds
swiftc probe.swift -o probe        # build the check tool
./probe                            # reports whether it loaded, formats, sample rates, volume controls, default output
./uninstall.sh                     # remove it and restart coreaudiod
```

Installing does not change the default output. macOS 26 loads ad-hoc signed plug-ins, so no paid developer account is needed.

`install.sh` and `uninstall.sh` use `sudo`; run them yourself in the Terminal app and enter your password there.
