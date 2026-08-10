# Blind-Guidence-System
# Blind Guidance System

Blind Guidance System is an assistive-navigation prototype for iPhone. It combines the phone's camera, depth sensing, AR mapping, and a local Python computer-vision server to identify walkable space and nearby obstacles. The app returns an annotated live camera view, produces directional audio cues, supports indoor LiDAR mesh scans, and includes quick-access location and emergency-simulation tools.

> **Important:** This is a prototype, not a safety-certified mobility aid. It must not be used as the sole means of navigation or obstacle avoidance. Always use appropriate mobility support and remain aware of the surrounding environment.

<!-- Replace each placeholder below with a screenshot stored in docs/images/. Example: ![Live guidance screen](docs/images/live-guidance.png) -->

## App preview

```text
┌──────────────────────────────────────────────────────────────────────────┐
│ PLACE APP SCREENSHOT: Live Guidance                                      │
│ Suggested file: docs/images/live-guidance.png                             │
│ Show: camera view, green walkable area, red route, obstacle labels, HUD. │
└──────────────────────────────────────────────────────────────────────────┘
```

```text
┌──────────────────────────────────────────────────────────────────────────┐
│ PLACE APP SCREENSHOT: LiDAR Scan / 3D Map                                │
│ Suggested file: docs/images/lidar-scan.png                                │
│ Show: scanning controls or a saved environment mesh.                      │
└──────────────────────────────────────────────────────────────────────────┘
```

```text
┌──────────────────────────────────────────────────────────────────────────┐
│ PLACE APP SCREENSHOT: Draw Valid Paths on 3D Map                          │
│ Suggested file: docs/images/map-path-annotation.png                       │
│ Show: top-down mesh with user-drawn red valid-path corridors.             │
└──────────────────────────────────────────────────────────────────────────┘
```

```text
┌──────────────────────────────────────────────────────────────────────────┐
│ PLACE APP SCREENSHOT: Quick Assist or Settings                            │
│ Suggested file: docs/images/quick-assist.png                              │
│ Show: location, emergency simulation, or server settings.                 │
└──────────────────────────────────────────────────────────────────────────┘
```

## What it does

- Streams camera frames and LiDAR depth data from the iOS app to a computer on the same network.
- Uses semantic segmentation to estimate the ground/walkable region.
- Uses instance segmentation to find substantial nearby objects such as chairs, couches, beds, tables, toilets, TVs, refrigerators, plants, suitcases, and benches.
- Removes detected obstacles from the walkable region, computes a safe central route, and detects nearby path splits.
- Sends an annotated JPEG back to the phone: green walkable areas, orange obstacle masks, labels, and a red route line.
- Plays spatialized warning beeps for the nearest obstacle and uses text-to-speech announcements for intersections and multiple obstacles.
- Captures LiDAR mesh anchors on-device and exports a colored Wavefront OBJ map to the app's Documents directory.
- Lets users scan familiar environments and draw known valid walking paths directly on the 3D map, providing an annotated route prior that can improve path guidance where a live camera view is limited, such as around sharp 90° turns or occluded areas.
- Provides a 3D-map browser, current-location speech, adjustable obstacle-alert distance UI, event logging, and an emergency-call simulation.

## Architecture

```text
iPhone camera + LiDAR
        │ ARFrame (JPEG image, depth, camera metadata)
        ▼
SwiftUI app ── WebSocket / JSON ──► Python server (port 8765)
        ▲                                  │
        └── annotated JPEG + FPS/latency ──┘
                                           │
                     SegFormer + YOLO instance segmentation
                                           │
                             route finding + desktop audio cues
```

The iPhone shows the returned visual overlay. The Python host currently produces the spatial beeps and server-side speech; its audio output should therefore be audible to the intended user during testing.

## Algorithms and methods

The system uses a hybrid of learned vision models, depth geometry, and deterministic path-planning heuristics. The exact implementation is summarized below.

| Task | Algorithm / model | How it is used |
| --- | --- | --- |
| Semantic segmentation | **SegFormer-B0** (`nvidia/segformer-b0-finetuned-ade-512-512`) | A transformer-based semantic-segmentation network predicts ADE20K classes. The server treats class IDs `3`, `11`, and `29` as candidate ground, then resizes the result to its 240 × 320 processing grid. |
| Ground-mask cleanup | **Morphological closing** with a 3 × 3 elliptical structuring element | Fills small holes and connects small gaps in the semantic ground mask. |
| Obstacle segmentation | **Ultralytics YOLO11n-seg** instance segmentation | Produces object detections and per-object masks. The server retains configured large-object classes, applies a confidence threshold of 0.35, and rejects boxes smaller than 600 pixels on the processing grid. |
| Obstacle distance | **Depth-mask percentile estimate** | The depth samples inside each object mask are filtered to valid values; the fifth percentile estimates the nearest visible surface of that object. Objects beyond 4.5 m are discarded. |
| Free-space construction | **Binary mask subtraction + morphological dilation** | Obstacle masks are removed from the ground mask, then dilated with a 5 × 5 elliptical kernel to add a safety margin. |
| Path-center selection | **Euclidean distance transform** (`cv2.distanceTransform`, L2, 3 × 3 mask) | Each free pixel is scored by its distance to the nearest non-walkable pixel. The planner selects the highest-score pixel within a candidate path segment, favoring maximum clearance from boundaries and obstacles. |
| Path following | **Bottom-up, band-based greedy tracking** | Beginning near the bottom-center of the image, the planner samples horizontal bands at fixed vertical steps. It splits each band into contiguous walkable segments, chooses the candidate nearest the previous center, and advances upward. |
| Junction detection | **Connected-segment branch expansion** | If a sampled band contains more than one sufficiently wide segment, the system expands a path through each branch and labels its endpoint as left, straight, or right. Nearby splits trigger an intersection announcement. |
| Temporal stability | **Exponential moving average (EMA)** | Consecutive primary routes are blended with the previous route so route lines do not jump sharply between frames. |
| Spatial warning audio | **Interaural level difference (ILD), interaural time difference (ITD), and rear low-pass filtering** | The nearest obstacle's horizontal image position becomes a ±60° azimuth. Stereo gain and a small opposite-ear delay create directional beeps; rear sound is low-pass filtered to simulate pinna shadowing. |
| User path annotation | **3D hit-testing, endpoint snapping, and straight-ribbon segments** | In the top-down map editor, touch points are ray/hit-tested against the mesh. New line endpoints snap to an existing endpoint within 0.45 m, and the saved line segments are persisted as JSON alongside the OBJ map. |

The server runs semantic segmentation every four frames and YOLO inference every two frames, reusing recent output between runs. This interleaving and the single-frame queue are intentional real-time latency optimizations.

## Technologies used

| Area | Technology | Purpose in this project |
| --- | --- | --- |
| iOS interface | SwiftUI | Builds the splash screen, navigation tabs, live view, scan controls, logs, and settings. |
| iOS sensing | ARKit and SceneKit | Provides AR world tracking, camera frames, LiDAR scene reconstruction, mesh anchors, and 3D map viewing. |
| iOS platform services | AVFoundation, Core Location, MapKit, AudioToolbox | Camera/image conversion, speech, location lookup, vibration, and quick-assist features. |
| Networking | `URLSessionWebSocketTask` and Python `websockets` | Sends frame payloads and receives processed results over a LAN WebSocket connection. |
| Server language | Python 3 | Runs the real-time inference and audio pipeline. |
| Vision | OpenCV, NumPy | Decodes images/depth, resizes and rotates frames, composites overlays, and performs morphology/distance transforms. |
| AI models | PyTorch, Hugging Face Transformers, Ultralytics YOLO | Runs SegFormer semantic segmentation and YOLO instance segmentation. |
| Audio | Pygame, SciPy, macOS `say` / Linux `espeak` | Generates stereo obstacle tones, filtering, and spoken alerts. |
| 3D mapping test tool | Open3D | Renders an incoming point cloud in the optional standalone mapping test server. |
| Assets/models | `.xcassets`, `.pt` weights | Stores app assets and local YOLO model checkpoints. |

## Repository layout

```text
.
├── ios/BlindGuidenceSystem/
│   ├── BlindGuidenceSystem.xcodeproj/   # Xcode project
│   └── BlindGuidenceSystem/              # SwiftUI app source
├── server/
│   ├── server.py                         # Main navigation/inference WebSocket server
│   ├── test_mapper.py                    # Optional Open3D point-cloud test server
│   ├── sound.py                           # Standalone spatial-audio demo
│   └── *.pt                              # Local YOLO weights
└── README.md
```

## Requirements

### iOS device

- A physical iPhone/iPad with a camera. The main Xcode target is currently configured with an iOS deployment target of **26.5**; use an Xcode/iOS SDK combination that supports that target, or deliberately lower it in the project settings if appropriate for your environment.
- A LiDAR-capable device is required for the **Scan** tab and scene-reconstruction mesh capture. The live camera interface may still run without LiDAR, but depth-based distance estimates and some AR capabilities depend on hardware support.
- Camera and location permissions when prompted.
- The iPhone and Python host must be on the same local network.

### Python server

- Python 3.10+ recommended.
- macOS, Linux, or Windows. GPU acceleration is optional: the server selects CUDA first, then Apple Metal Performance Shaders (MPS), then CPU.
- Headphones or speakers connected to the server host for the server-generated audio cues.
- Internet access on the first run if the SegFormer checkpoint is not already cached locally. YOLO weights used by the main server are included in `server/`.

## Setup and run

### 1. Clone the repository

```bash
git clone <your-repository-url>
cd BlindGuidenceSystem-Server
```

### 2. Create a Python environment

From the repository root:

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
pip install opencv-python numpy torch torchvision websockets pygame scipy ultralytics transformers
```

For the optional point-cloud test utility, install Open3D as well:

```bash
pip install open3d
```

> If PyTorch installation needs a platform-specific build—especially for CUDA—follow the installation selector on the official PyTorch website, then install the remaining packages.

### 3. Start the navigation server

Run this from the `server` directory so the relative YOLO model path resolves correctly:

```bash
cd server
python server.py
```

Expected startup output includes a line similar to:

```text
Ground-Truth Panoptic Server active on ws://0.0.0.0:8765
```

The first launch can take longer while the segmentation model is loaded or downloaded. Keep this terminal open while using the app.

### 4. Find the server host's LAN address

Use the address associated with the same Wi-Fi network as the iPhone. On macOS, for example:

```bash
ipconfig getifaddr en0
```

If that interface has no address, inspect available interfaces with `ifconfig`. Do not use `0.0.0.0` in the app: it is only the server's bind address. Use a reachable address such as `192.168.x.x` instead.

### 5. Configure and run the iOS app

1. Open `ios/BlindGuidenceSystem/BlindGuidenceSystem.xcodeproj` in Xcode.
2. Select the **BlindGuidenceSystem** scheme and your physical device.
3. In the target's **Info** settings, give **Privacy - Camera Usage Description** a non-empty explanation. The project currently has this generated value set to an empty string. Keep or customize the existing location-usage explanation as well.
4. Set a valid Development Team and, if necessary, a unique bundle identifier for code signing.
5. Build and run the app.
6. Grant camera and location permission when iOS asks.
7. Open the app's **Settings** tab and enter the Python host's LAN IP address and port `8765`.
8. Return to **Live** and point the camera toward a clear, well-lit indoor scene.

The default server IP in the source is a private-network example and will likely need to be changed for your network.

## Using the app

### Live guidance

On launch, choose an existing annotated map or select **Skip to Live View**. The live screen sends AR camera frames to the server. Once connected, the returned overlay highlights estimated free ground, masks obstacles, and draws a suggested path. The diagnostic HUD can display connection state, frame rate, and processing latency.

Keep the camera oriented steadily and give the system enough light and visible floor area. Network delay, image quality, model confidence, and depth quality all affect the result.

### LiDAR scan, familiar-environment maps, and valid-path drawing

The **Scan** tab is designed for places a user visits regularly, such as a home, school, or workplace. Start a scan and move through the environment—including around corners, entrances, and sharp 90° turns—so ARKit can reconstruct a larger 3D mesh than a single camera view can see. When the scan stops, the app exports the colored mesh as a Wavefront OBJ file in the app's Documents directory.

This stored spatial context is intended to supplement camera-based understanding. In the annotation-capable navigation flow, paths drawn on the saved 3D map are projected into the current AR camera frame as normalized 2D line segments. The server renders those lines into its ground mask as authoritative walkable corridors before running the distance-transform path planner. With reliable relocalization in the same scanned coordinate space, this makes known valid routes available when the camera cannot yet see all of a route—for example, around a sharp 90° turn or beyond an occluded doorway.

To create valid-path annotations:

1. Open **Logs** and select the saved OBJ map, or tap the orange pen icon beside it.
2. Switch to **Top-Down Draw** mode if needed.
3. Draw the valid walking corridors directly over the 3D mesh. Each stroke becomes a straight red ribbon; endpoints within 0.45 m automatically snap together to make connected routes easier to create.
4. Use **Clear** to remove unsaved lines, or **Save Copy** to create an annotated OBJ plus a companion JSON file containing the 3D path segments.
5. Select the annotated map when launching the annotation-capable live-navigation view. Its 3D path segments are projected into the AR view and fused with the live semantic ground mask.

The map is a route prior, not a substitute for live sensing: the server still subtracts currently detected obstacles and uses current depth before selecting the final path.

> **Current implementation note:** The repository includes 3D annotation persistence and projection code, but it does not yet persist or restore an `ARWorldMap` for cross-session relocalization. As a result, the intended “remember routes around unseen corners” behavior is only geometrically reliable while the scan and annotation-aware navigation share a correctly aligned AR coordinate system. Persisting/restoring an `ARWorldMap` (or adding another robust map-localization method) is required for dependable reuse of annotated maps across separate launches.

### Quick Assist

- **Where Am I?** requests a location and reads an approximate nearby address using Apple Maps search.
- **Call Emergency** is explicitly a simulation: it vibrates and announces a simulated call; it does not place a phone call.
- **Obstacle Alert Distance** stores a 1 m, 2 m, or 3 m UI preference. Review and connect this preference to server-side filtering if you want it to alter the current server behavior.

### Settings and logs

Settings persist the server IP, port, overlay opacity, guidance options, debug HUD setting, and alert-distance preference using `@AppStorage`. The logs section lists saved map files and system events, and supports viewing, sharing, or deleting exported maps.

## WebSocket protocol

The main server listens on `ws://<server-ip>:8765` and accepts JSON text messages. A frame payload contains a Base64 JPEG image and may include Base64 Float32 depth data, intrinsics, transform values, normalized map annotation lines, mode, and an action.

Conceptual request:

```json
{
  "image": "<base64 JPEG>",
  "depth": "<optional base64 Float32 depth buffer>",
  "intrinsics": ["..."],
  "transform": ["..."],
  "normalized_lines": [[0.1, 0.9, 0.5, 0.4]]
}
```

Successful responses contain:

```json
{
  "status": "success",
  "mask": "<base64 JPEG of annotated frame>",
  "fps": 12.3,
  "latency_ms": 81.4
}
```

The server keeps only the most recent queued frame to favor responsiveness over processing every captured frame. SegFormer and YOLO inference are also interleaved/cached to reduce latency.

## Server processing pipeline

1. Decode and rotate the incoming JPEG into portrait orientation.
2. Decode, rotate, and resize LiDAR depth data when available.
3. Run SegFormer-B0 (`nvidia/segformer-b0-finetuned-ade-512-512`) periodically, select its configured ground classes, and close small gaps morphologically.
4. Merge any app-supplied normalized walkable annotation lines—projected from a saved, annotated 3D LiDAR map—into the ground mask as authoritative corridors.
5. Run YOLO11 nano instance segmentation periodically, estimate distance from the fifth percentile of each mask's depth samples, and retain qualifying large nearby obstacles.
6. Subtract and dilate obstacle regions from the walkable mask.
7. Use a Euclidean distance transform plus bottom-up greedy band tracking to select clearance-maximizing path centers and identify path branches.
8. Draw the overlay, return it to the phone, and generate audio feedback on the server host.

## Optional utilities

Run the standalone spatial-audio test from `server/`:

```bash
python sound.py
```

It plays a soft tone orbiting around the listener; use headphones for the intended stereo effect.

Run the optional Open3D mapping viewer:

```bash
python test_mapper.py
```

It starts a separate WebSocket server on port `8766` and displays incoming image/depth/intrinsics/transform payloads as an accumulated point cloud. This is a development/test utility, separate from the main `server.py` navigation path.

## Troubleshooting

| Problem | Things to check |
| --- | --- |
| The app does not connect | Confirm both devices are on the same LAN, the IP/port in Settings are correct, `server.py` is running, and the host firewall allows TCP port 8765. |
| The app connects but no overlay appears | Check the server terminal for model or decoding errors; ensure the app is sending camera frames and use a well-lit scene. |
| No obstacle distances or unreliable distances | Use a LiDAR/depth-capable device, keep the sensor unobstructed, and scan within the server's configured distance range. |
| First start is slow or fails while loading SegFormer | Confirm internet access and available disk space, or pre-cache the Hugging Face model on the server host. |
| Audio is missing | Check the Python host's audio device and volume. On Linux, install `espeak-ng` or `espeak` for speech. Use headphones for spatial tone testing. |
| Xcode cannot install the app | Configure signing, select a physical device, and make sure your installed Xcode supports the target's configured iOS deployment version. |
| LiDAR scan says unsupported | The selected device does not support ARKit scene reconstruction with mesh; use a LiDAR-capable iPhone/iPad. |

## Configuration notes

The main tuning values are at the top of [`server/server.py`](server/server.py): processing resolution, segmentation/detection cadence, JPEG quality, detection confidence, maximum obstacle distance, and audio timing. The app's saved connection and display preferences live in [`ios/BlindGuidenceSystem/BlindGuidenceSystem/AppState.swift`](ios/BlindGuidenceSystem/BlindGuidenceSystem/AppState.swift).

For production deployment, consider adding authenticated/encrypted transport, explicit permission strings in `Info.plist`, model/version management, a dependency lock file, automated tests, and robust safety validation before relying on any navigation feedback.

## License

No license file is currently included. Add a license before distributing or accepting external contributions.
