# WK68 Control for macOS

A native macOS lighting controller for the wired **WEIKAV WK68** keyboard
(`258A:010C`, model signature `01 CA`).

## Features

- Automatic apply with no separate Apply button
- All official keyboard lighting effects
- Universal keyboard color
- Per-key color painting with click-to-select and click-again-to-deselect
- Bottom-light mode, fixed color, multicolor, brightness, and speed controls
- Restore captured bottom-light settings
- Model handshake and `5A A5` configuration safety validation before writes
- Guarded HID reads with retry handling for transient USB errors

## Requirements

- macOS 13 or later
- Apple Command Line Tools (`clang` and `codesign`)
- WK68 connected by USB and placed in wired mode
- Input Monitoring permission for the built app

## Build

```sh
./build.sh
```

The application is created at `dist/WK68 Control.app` and signed locally with
a stable designated requirement.

## Safety

The app opens only the vendor HID interface matching VID/PID `258A:010C`,
verifies the keyboard's `01 CA` model response, reads the current configuration,
and preserves unknown bytes. A configuration write is rejected unless the
136-byte payload contains the expected `5A A5` safety marker.

## Notes

This is an independent community project and is not affiliated with WEIKAV.

