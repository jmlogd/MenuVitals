# MenuVitals

MenuVitals displays CPU usage, memory use, and network throughput in the macOS menu bar. Click the readings to see a summary or choose which metrics to monitor under **Settings**. Preferences persist between launches.

## Build and run

Open MenuVitals.xcodeproj in Xcode 27 or later, select the MenuVitals scheme and My Mac destination, then press Command-R. The deployment target is macOS 27.0. The app uses local signing and App Sandbox.

The app samples local operating system counters every two seconds. It uses native frameworks and bundles Hugeicons SVG assets, including Activity 04 (Stroke Rounded) as its app icon. Their license is in Hugeicons-LICENSE.txt.
