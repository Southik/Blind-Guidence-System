# SERVER URL: ws://192.__.__.__:8765 (ipconfig getifaddr en0)
import os
import time

# --- Suppress startup outputs ---
os.environ["USE_TF"] = "0"
os.environ["TF_ENABLE_ONEDNN_OPTS"] = "0"
os.environ["PYGAME_HIDE_SUPPORT_PROMPT"] = "1"

import asyncio
import base64
import json
import queue
import shutil
import subprocess
import sys
import threading

import cv2
import numpy as np
import torch
import torch.nn.functional as F
import websockets
import pygame
from scipy.signal import butter, sosfilt
from ultralytics import YOLO
from transformers import SegformerForSemanticSegmentation


PROC_W = 240
PROC_H = 320
SEG_SIZE = 224                    # SegFormer input resolution
SEGMENTATION_EVERY_N_FRAMES = 4   # Interleaved SegFormer pass
DETECTION_EVERY_N_FRAMES = 2      # Interleaved YOLO pass
JPEG_QUALITY = 55

CONFIDENCE_THRESHOLD = 0.35
MAX_DETECTION_DISTANCE = 4.5
MIN_BOX_AREA = 600

MAX_CACHED_INFERENCE_AGE = 0.75

# Audio
SAMPLE_RATE = 44100
HEAD_RADIUS = 0.0875
SPEED_OF_SOUND = 343.0
OBSTACLE_ANNOUNCE_COOLDOWN = 5.0
MANY_OBSTACLES_THRESHOLD = 3

LARGE_OBSTACLE_CLASSES = {
    "chair", "couch", "bed", "dining table", "toilet", "tv",
    "refrigerator", "potted plant", "suitcase", "bench"
}

if torch.cuda.is_available():
    device = torch.device("cuda")
    use_fp16 = True
elif torch.backends.mps.is_available():
    device = torch.device("mps")
    use_fp16 = True
else:
    device = torch.device("cpu")
    use_fp16 = False

if torch.cuda.is_available():
    torch.backends.cudnn.benchmark = True
    torch.set_float32_matmul_precision("high")

print(f"🚀 High-FPS Panoptic Navigation Engine: {device} (FP16={use_fp16})")


# AUDIO ENGINE
pygame.mixer.pre_init(
    frequency=SAMPLE_RATE,
    size=-16,
    channels=2,
    buffer=128,
)
pygame.mixer.init()

_BEEP_T = np.arange(int(SAMPLE_RATE * 0.04), dtype=np.float32) / SAMPLE_RATE
_BEEP = np.sin(2.0 * np.pi * 680.0 * _BEEP_T).astype(np.float32)
_FADE = max(1, int(SAMPLE_RATE * 0.003))
_BEEP[:_FADE] *= np.linspace(0.0, 1.0, _FADE, dtype=np.float32)
_BEEP[-_FADE:] *= np.linspace(1.0, 0.0, _FADE, dtype=np.float32)
_BEEP *= 0.5

_BACK_SOS = butter(2, 2200, "low", fs=SAMPLE_RATE, output="sos")

audio_queue = queue.Queue(maxsize=1)

voice_condition = threading.Condition()
pending_voice = None
voice_process = None
voice_stop = False

LAST_AUDIO_TIME = 0.0
LAST_INTERSECTION_ANNOUNCED = ""
LAST_INTERSECTION_TIME = 0.0
LAST_OBSTACLE_ANNOUNCEMENT = ""
LAST_OBSTACLE_ANNOUNCEMENT_TIME = 0.0


def speak_text(text):
    global voice_process
    try:
        if sys.platform == "darwin":
            return subprocess.Popen(
                ["say", "-r", "220", text],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )

        if shutil.which("espeak-ng"):
            return subprocess.Popen(
                ["espeak-ng", "-s", "190", text],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )

        if shutil.which("espeak"):
            return subprocess.Popen(
                ["espeak", "-s", "190", text],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )

        print(f"🗣️ [VOICE ANNOUNCEMENT]: {text}")
        return None
    except Exception as exc:
        print(f"⚠️ Voice Error: {exc}")
        return None


def queue_voice(text, priority=0):
    global pending_voice
    with voice_condition:
        if pending_voice is None:
            pending_voice = (priority, text)
        else:
            old_priority, _ = pending_voice
            if priority >= old_priority:
                pending_voice = (priority, text)
            else:
                return

        if priority >= 2 and voice_process is not None:
            try:
                if voice_process.poll() is None:
                    voice_process.terminate()
            except Exception:
                pass

        voice_condition.notify()


def voice_worker():
    global pending_voice, voice_process, voice_stop
    while True:
        with voice_condition:
            while pending_voice is None and not voice_stop:
                voice_condition.wait()

            if voice_stop:
                return

            _, text = pending_voice
            pending_voice = None

        try:
            if voice_process is not None:
                try:
                    if voice_process.poll() is None:
                        voice_process.terminate()
                        voice_process.wait(timeout=0.05)
                except Exception:
                    try:
                        voice_process.kill()
                    except Exception:
                        pass

            voice_process = speak_text(text)
        except Exception as exc:
            print(f"⚠️ Voice Thread Error: {exc}")


threading.Thread(target=voice_worker, daemon=True, name="voice-worker").start()


def apply_pinna_filter(signal, is_back=False):
    if not is_back:
        return signal
    return sosfilt(_BACK_SOS, signal)


def spatialize(mono_signal, azimuth_deg):
    rad = np.radians(azimuth_deg % 360.0)
    is_back = 90.0 < (azimuth_deg % 360.0) < 270.0
    processed_signal = apply_pinna_filter(mono_signal, is_back=is_back)

    pan = (np.sin(rad) + 1.0) / 2.0
    gain_l = np.cos(pan * np.pi / 2.0) ** 1.8
    gain_r = np.sin(pan * np.pi / 2.0) ** 1.8

    delay_sec = (HEAD_RADIUS / SPEED_OF_SOUND) * (
        np.abs(np.sin(rad)) + np.abs(rad % np.pi - np.pi / 2.0)
    )
    delay_samples = int(delay_sec * SAMPLE_RATE)

    stereo = np.zeros((len(processed_signal) + delay_samples, 2), dtype=np.float32)

    if np.sin(rad) >= 0:
        stereo[:len(processed_signal), 1] = processed_signal * gain_r
        stereo[delay_samples:delay_samples + len(processed_signal), 0] = (
            processed_signal * gain_l
        )
    else:
        stereo[:len(processed_signal), 0] = processed_signal * gain_l
        stereo[delay_samples:delay_samples + len(processed_signal), 1] = (
            processed_signal * gain_r
        )

    return stereo


SPATIAL_SOUNDS = {}
for _az in range(-60, 61):
    _stereo = spatialize(_BEEP, float(_az))
    _audio_int16 = np.int16(np.clip(_stereo, -1.0, 1.0) * 32767)
    SPATIAL_SOUNDS[_az] = pygame.sndarray.make_sound(_audio_int16)


def audio_worker():
    while True:
        try:
            azimuth_deg = audio_queue.get(block=True)
            if azimuth_deg is None:
                return

            azimuth_int = int(round(float(azimuth_deg)))
            azimuth_int = max(-60, min(60, azimuth_int))
            sound = SPATIAL_SOUNDS.get(azimuth_int)

            if sound is not None:
                pygame.mixer.stop()
                sound.play()

            audio_queue.task_done()
        except Exception as exc:
            print(f"⚠️ Audio Worker Error: {exc}")


threading.Thread(target=audio_worker, daemon=True, name="audio-worker").start()


def announce_intersection_if_needed(directions, split_is_close):
    global LAST_INTERSECTION_ANNOUNCED, LAST_INTERSECTION_TIME

    if not directions or len(directions) < 2 or not split_is_close:
        return

    now = time.perf_counter()
    directions_key = ", ".join(sorted(directions))

    if (
        directions_key == LAST_INTERSECTION_ANNOUNCED
        and now - LAST_INTERSECTION_TIME < 5.0
    ):
        return

    LAST_INTERSECTION_ANNOUNCED = directions_key
    LAST_INTERSECTION_TIME = now

    if len(directions) > 2:
        dirs_str = ", ".join(directions[:-1]) + " and " + directions[-1]
    else:
        dirs_str = " and ".join(directions)

    queue_voice(f"Intersection ahead. Options are {dirs_str}.", priority=2)


def trigger_obstacle_warning_audio(closest_obstacle, image_width):
    global LAST_AUDIO_TIME

    if closest_obstacle is None:
        return

    min_dist, x_center = closest_obstacle
    now = time.perf_counter()

    beep_interval = max(0.10, min(0.50, min_dist * 0.10))
    if now - LAST_AUDIO_TIME < beep_interval:
        return

    LAST_AUDIO_TIME = now

    center_x = image_width / 2.0
    norm_offset = (x_center - center_x) / max(center_x, 1.0)
    azimuth_deg = float(np.clip(norm_offset * 60.0, -60.0, 60.0))

    try:
        if audio_queue.full():
            audio_queue.get_nowait()
            audio_queue.task_done()
    except queue.Empty:
        pass

    try:
        audio_queue.put_nowait(azimuth_deg)
    except queue.Full:
        pass


def describe_obstacles(obstacles, image_width):
    bins = {"left": [], "center": [], "right": []}
    left_thresh = image_width * 0.33
    right_thresh = image_width * 0.66

    for name, dist, x_center in obstacles:
        if x_center < left_thresh:
            bins["left"].append((name, dist))
        elif x_center > right_thresh:
            bins["right"].append((name, dist))
        else:
            bins["center"].append((name, dist))

    parts = []
    for direction, label in (
        ("left", "left"),
        ("center", "ahead"),
        ("right", "right"),
    ):
        if bins[direction]:
            name, dist = min(bins[direction], key=lambda item: item[1])
            parts.append(f"{name}, {dist:.1f} meters {label}")

    return ", ".join(parts)


def announce_obstacles_if_needed(obstacles, image_width):
    global LAST_OBSTACLE_ANNOUNCEMENT, LAST_OBSTACLE_ANNOUNCEMENT_TIME

    if len(obstacles) < MANY_OBSTACLES_THRESHOLD:
        return

    description = describe_obstacles(obstacles, image_width)
    if not description:
        return

    now = time.perf_counter()
    if (
        description == LAST_OBSTACLE_ANNOUNCEMENT
        and now - LAST_OBSTACLE_ANNOUNCEMENT_TIME < OBSTACLE_ANNOUNCE_COOLDOWN
    ):
        return

    LAST_OBSTACLE_ANNOUNCEMENT = description
    LAST_OBSTACLE_ANNOUNCEMENT_TIME = now
    queue_voice(f"Multiple obstacles ahead. {description}.", priority=1)


# MODEL SETUP

SEGFORMER_NAME = "nvidia/segformer-b0-finetuned-ade-512-512"

segformer_model = (
    SegformerForSemanticSegmentation
    .from_pretrained(SEGFORMER_NAME)
    .to(device)
)
if use_fp16:
    segformer_model = segformer_model.half()
segformer_model.eval()

GROUND_CLASSES = torch.tensor([3, 11, 29], device=device)

# Using YOLO Instance Segmentation model for panoptic obstacle masks
yolo_model = YOLO("yolo11n-seg.pt")
yolo_model.to(device)

try:
    dummy = np.zeros((PROC_H, PROC_W, 3), dtype=np.uint8)
    yolo_model(
        dummy,
        conf=CONFIDENCE_THRESHOLD,
        imgsz=256,
        half=use_fp16,
        verbose=False,
    )
except Exception as exc:
    print(f"⚠️ YOLO warm-up skipped: {exc}")

try:
    dummy_seg = torch.zeros(
        (1, 3, SEG_SIZE, SEG_SIZE),
        device=device,
        dtype=torch.float16 if use_fp16 else torch.float32,
    )
    with torch.inference_mode():
        segformer_model(pixel_values=dummy_seg)
except Exception as exc:
    print(f"⚠️ SegFormer warm-up skipped: {exc}")


# PATHFINDING
PREV_PRIMARY_PATH = None
CACHED_GROUND_MASK_SMALL = None
FRAME_COUNTER = 0

CACHED_YOLO = None
CACHED_YOLO_TIME = 0.0


def get_band_indices(walkable_mask, y, band_half=2):
    h = walkable_mask.shape[0]
    y0 = max(0, y - band_half)
    y1 = min(h, y + band_half + 1)
    band = walkable_mask[y0:y1, :]
    combined = band.max(axis=0)
    return np.flatnonzero(combined)


def pick_segment_center(seg, dist_transform, y):
    row_dist = dist_transform[y, seg]
    return int(seg[int(np.argmax(row_dist))])


def smooth_primary_path(new_path, prev_path, alpha=0.35):
    if not new_path or not prev_path or len(prev_path) != len(new_path):
        return new_path

    return [
        (int(alpha * px + (1.0 - alpha) * nx), ny)
        for (nx, ny), (px, _py) in zip(new_path, prev_path)
    ]


def find_all_walkable_paths(
    walkable_mask,
    dist_transform,
    step_size=12,
    min_seg_width=15,
    band_half=2,
):
    h_img, w_img = walkable_mask.shape
    start_x = w_img // 2
    start_y = h_img - 5

    start_indices = get_band_indices(walkable_mask, start_y, band_half)
    if len(start_indices) == 0:
        return [], [], False

    if start_x not in start_indices:
        start_x = int(start_indices[np.argmin(np.abs(start_indices - start_x))])

    branches = []
    split_found = False
    split_y = -1
    primary_path = [(start_x, start_y)]
    current_x = start_x

    for y in range(start_y - step_size, int(h_img * 0.2), -step_size):
        walkable_indices = get_band_indices(walkable_mask, y, band_half)
        if len(walkable_indices) == 0:
            break

        splits = np.flatnonzero(np.diff(walkable_indices) > 1)
        segments = np.split(walkable_indices, splits + 1)
        valid_segments = [s for s in segments if len(s) >= min_seg_width]

        if len(valid_segments) > 1 and not split_found:
            split_found = True
            split_y = y

            for seg in valid_segments:
                seg_center = pick_segment_center(seg, dist_transform, y)
                branch_path = list(primary_path) + [(seg_center, y)]

                b_x = seg_center
                for sub_y in range(
                    y - step_size,
                    int(h_img * 0.2),
                    -step_size,
                ):
                    sub_walkable = get_band_indices(
                        walkable_mask, sub_y, band_half
                    )
                    if len(sub_walkable) == 0:
                        break

                    sub_splits = np.flatnonzero(np.diff(sub_walkable) > 1)
                    sub_segs = np.split(sub_walkable, sub_splits + 1)
                    candidate_segs = (
                        [s for s in sub_segs if len(s) >= min_seg_width]
                        or sub_segs
                    )

                    if not candidate_segs:
                        break

                    centers = np.array(
                        [
                            pick_segment_center(s, dist_transform, sub_y)
                            for s in candidate_segs
                            if len(s) > 0
                        ],
                        dtype=np.int32,
                    )
                    if len(centers) == 0:
                        break

                    best_sub_center = int(
                        centers[np.argmin(np.abs(centers - b_x))]
                    )
                    b_x = int(0.6 * b_x + 0.4 * best_sub_center)
                    branch_path.append((b_x, sub_y))

                branches.append(branch_path)
            break

        if len(valid_segments) > 0:
            centers = [
                pick_segment_center(s, dist_transform, y)
                for s in valid_segments
            ]
            best_idx = int(np.argmin(np.abs(np.asarray(centers) - current_x)))
            target_x = centers[best_idx]
            current_x = int(0.6 * current_x + 0.4 * target_x)
            primary_path.append((current_x, y))

    all_paths = (
        branches
        if split_found
        else ([primary_path] if len(primary_path) >= 2 else [])
    )

    directions = []
    center_x = w_img / 2.0
    left_thresh = center_x - (w_img * 0.20)
    right_thresh = center_x + (w_img * 0.20)

    for path in all_paths:
        if len(path) < 2:
            continue

        end_x = path[-1][0]
        if end_x < left_thresh:
            direction = "left"
        elif end_x > right_thresh:
            direction = "right"
        else:
            direction = "straight"

        if direction not in directions:
            directions.append(direction)

    split_is_close = split_found and split_y >= int(h_img * 0.45)
    return all_paths, directions, split_is_close


def draw_paths_overlay(frame, all_paths, scale_x, scale_y):
    if not all_paths:
        return

    for path in all_paths[1:]:
        pts = np.asarray(
            [(int(x * scale_x), int(y * scale_y)) for x, y in path],
            dtype=np.int32,
        ).reshape((-1, 1, 2))

        cv2.polylines(
            frame,
            [pts],
            isClosed=False,
            color=(255, 255, 0),
            thickness=5,
            lineType=cv2.LINE_AA,
        )

    primary_path = all_paths[0]
    pts_prim = np.asarray(
        [(int(x * scale_x), int(y * scale_y)) for x, y in primary_path],
        dtype=np.int32,
    ).reshape((-1, 1, 2))

    cv2.polylines(
        frame,
        [pts_prim],
        isClosed=False,
        color=(0, 0, 200),
        thickness=8,
        lineType=cv2.LINE_AA,
    )
    cv2.polylines(
        frame,
        [pts_prim],
        isClosed=False,
        color=(0, 0, 255),
        thickness=4,
        lineType=cv2.LINE_AA,
    )

    last_point = tuple(pts_prim[-1, 0])
    cv2.circle(
        frame,
        last_point,
        7,
        (0, 0, 255),
        -1,
        lineType=cv2.LINE_AA,
    )


# INFERENCE HELPERS
def run_segmentation(frame_portrait):
    small_seg_input = cv2.resize(
        frame_portrait,
        (SEG_SIZE, SEG_SIZE),
        interpolation=cv2.INTER_LINEAR,
    )
    small_rgb = cv2.cvtColor(small_seg_input, cv2.COLOR_BGR2RGB)

    tensor_img = (
        torch.from_numpy(small_rgb)
        .permute(2, 0, 1)
        .unsqueeze(0)
        .to(device, non_blocking=True)
    )

    tensor_img = tensor_img.half() if use_fp16 else tensor_img.float()
    tensor_img.div_(255.0)

    with torch.inference_mode():
        outputs = segformer_model(pixel_values=tensor_img)
        logits_upsampled = F.interpolate(
            outputs.logits,
            size=(PROC_H, PROC_W),
            mode="bilinear",
            align_corners=False,
        )
        pred_classes = torch.argmax(logits_upsampled[0], dim=0)
        is_ground = torch.isin(pred_classes, GROUND_CLASSES)

    ground_mask_raw = is_ground.to(torch.uint8).cpu().numpy()

    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (3, 3))
    smoothed_ground = cv2.morphologyEx(ground_mask_raw, cv2.MORPH_CLOSE, kernel)
    return smoothed_ground


def run_yolo(frame_small):
    return yolo_model(
        frame_small,
        conf=CONFIDENCE_THRESHOLD,
        imgsz=256,
        half=use_fp16,
        verbose=False,
    )[0]


def decode_depth(data, proc_w, proc_h):
    if not data.get("depth"):
        return None

    try:
        depth_bytes = base64.b64decode(data["depth"])
        depth_arr = np.frombuffer(depth_bytes, dtype=np.float32)
        num_pixels = depth_arr.size

        if num_pixels == 49152:
            depth_w, depth_h = 256, 192
        else:
            aspect_ratio = 4.0 / 3.0
            depth_h = int(np.sqrt(num_pixels / aspect_ratio))
            depth_w = int(depth_h * aspect_ratio)

        if depth_w * depth_h != num_pixels:
            return None

        depth_map_raw = depth_arr.reshape((depth_h, depth_w))
        depth_portrait = cv2.rotate(
            depth_map_raw,
            cv2.ROTATE_90_CLOCKWISE,
        )
        return cv2.resize(
            depth_portrait,
            (proc_w, proc_h),
            interpolation=cv2.INTER_LINEAR,
        )
    except Exception:
        return None


# FRAME PROCESSING
def process_single_frame(data):
    global PREV_PRIMARY_PATH
    global CACHED_GROUND_MASK_SMALL
    global FRAME_COUNTER
    global CACHED_YOLO
    global CACHED_YOLO_TIME

    FRAME_COUNTER += 1
    frame_start = time.perf_counter()

    try:
        image_bytes = base64.b64decode(data["image"])
        np_arr = np.frombuffer(image_bytes, np.uint8)
        frame_raw = cv2.imdecode(np_arr, cv2.IMREAD_COLOR)
    except Exception:
        return None

    if frame_raw is None:
        return None

    frame_portrait = cv2.rotate(frame_raw, cv2.ROTATE_90_CLOCKWISE)
    h_port, w_port = frame_portrait.shape[:2]

    scale_x = w_port / float(PROC_W)
    scale_y = h_port / float(PROC_H)

    frame_small = cv2.resize(
        frame_portrait,
        (PROC_W, PROC_H),
        interpolation=cv2.INTER_AREA,
    )

    composite_frame = frame_portrait.copy()

    depth_map = decode_depth(data, PROC_W, PROC_H)
    has_depth = depth_map is not None

    # Ground Segmentation Pass
    seg_is_due = (
        CACHED_GROUND_MASK_SMALL is None
        or FRAME_COUNTER % SEGMENTATION_EVERY_N_FRAMES == 0
    )

    if seg_is_due:
        try:
            CACHED_GROUND_MASK_SMALL = run_segmentation(frame_portrait)
        except Exception as exc:
            if CACHED_GROUND_MASK_SMALL is None:
                print(f"⚠️ Segmentation error: {exc}")

    if CACHED_GROUND_MASK_SMALL is None:
        return None

    ground_mask = CACHED_GROUND_MASK_SMALL.copy()

    # GROUND TRUTH RED-LINE ANNOTATION FUSION
    normalized_lines = data.get("normalized_lines", [])
    if normalized_lines:
        annotation_mask = np.zeros((PROC_H, PROC_W), dtype=np.uint8)
        for line in normalized_lines:
            if len(line) == 4:
                x1 = int(line[0] * PROC_W)
                y1 = int(line[1] * PROC_H)
                x2 = int(line[2] * PROC_W)
                y2 = int(line[3] * PROC_H)
                
                # Render thick walkable channel onto ground truth mask
                cv2.line(annotation_mask, (x1, y1), (x2, y2), 1, thickness=22)

        # Fuse annotations into ground mask as authoritative ground truth
        ground_mask = cv2.bitwise_or(ground_mask, annotation_mask)

    # YOLO Instance Segmentation Pass
    detection_is_due = (
        CACHED_YOLO is None
        or FRAME_COUNTER % DETECTION_EVERY_N_FRAMES == 0
        or time.perf_counter() - CACHED_YOLO_TIME > MAX_CACHED_INFERENCE_AGE
    )

    if detection_is_due:
        try:
            CACHED_YOLO = run_yolo(frame_small)
            CACHED_YOLO_TIME = time.perf_counter()
        except Exception as exc:
            if CACHED_YOLO is None:
                print(f"⚠️ YOLO error: {exc}")

    results = CACHED_YOLO

    obstacle_mask = np.zeros((PROC_H, PROC_W), dtype=np.uint8)
    obstacle_overlay_mask = np.zeros((h_port, w_port), dtype=bool)

    closest_obstacle = None
    min_obstacle_dist = float("inf")
    all_obstacles = []

    if results is not None and results.boxes is not None and len(results.boxes):
        boxes = results.boxes.xyxy.cpu().numpy()
        classes = results.boxes.cls.cpu().numpy()

        has_masks = results.masks is not None
        if has_masks:
            raw_masks = results.masks.data.cpu().numpy()

        for i, box_coords in enumerate(boxes):
            x1_s, y1_s, x2_s, y2_s = map(int, box_coords)

            x1_s = max(0, min(PROC_W - 1, x1_s))
            y1_s = max(0, min(PROC_H - 1, y1_s))
            x2_s = max(x1_s + 1, min(PROC_W, x2_s))
            y2_s = max(y1_s + 1, min(PROC_H, y2_s))

            obj_name = results.names[int(classes[i])]
            box_area = (x2_s - x1_s) * (y2_s - y1_s)

            if obj_name not in LARGE_OBSTACLE_CLASSES or box_area < MIN_BOX_AREA:
                continue

            if has_masks and i < len(raw_masks):
                obj_mask_small = cv2.resize(
                    raw_masks[i],
                    (PROC_W, PROC_H),
                    interpolation=cv2.INTER_LINEAR,
                ) > 0.5
            else:
                obj_mask_small = np.zeros((PROC_H, PROC_W), dtype=bool)
                obj_mask_small[y1_s:y2_s, x1_s:x2_s] = True

            min_dist = float("inf")
            if has_depth:
                box_depths = depth_map[obj_mask_small]
                valid_depths = box_depths[
                    (box_depths > 0.1) & np.isfinite(box_depths)
                ]
                if valid_depths.size:
                    min_dist = float(np.percentile(valid_depths, 5))

            if min_dist >= MAX_DETECTION_DISTANCE:
                continue

            obstacle_mask[obj_mask_small] = 1

            obj_mask_full = cv2.resize(
                obj_mask_small.astype(np.uint8),
                (w_port, h_port),
                interpolation=cv2.INTER_NEAREST,
            ).astype(bool)

            obstacle_overlay_mask |= obj_mask_full

            x1_f = int(x1_s * scale_x)
            y1_f = int(y1_s * scale_y)
            x2_f = int(x2_s * scale_x)

            label_text = (
                f"{obj_name} {min_dist:.1f}m"
                if has_depth and np.isfinite(min_dist)
                else obj_name
            )

            font = cv2.FONT_HERSHEY_SIMPLEX
            (text_w, text_h), _ = cv2.getTextSize(label_text, font, 0.55, 2)
            lbl_y1 = max(0, y1_f - text_h - 8)

            cv2.rectangle(
                composite_frame,
                (x1_f, lbl_y1),
                (x1_f + text_w + 10, y1_f),
                (0, 100, 255),
                -1,
            )
            cv2.putText(
                composite_frame,
                label_text,
                (x1_f + 5, max(text_h + 2, y1_f - 3)),
                font,
                0.55,
                (255, 255, 255),
                2,
                cv2.LINE_AA,
            )

            obj_center_x = (x1_f + x2_f) / 2.0
            all_obstacles.append((obj_name, min_dist, obj_center_x))

            if min_dist < min_obstacle_dist:
                min_obstacle_dist = min_dist
                closest_obstacle = (min_dist, obj_center_x)

    # Pathfinding on fused ground truth mask
    walkable_mask = cv2.bitwise_and(
        ground_mask,
        cv2.bitwise_not(obstacle_mask),
    )

    obs_kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5))
    dilated_obstacles = cv2.dilate(obstacle_mask, obs_kernel)
    walkable_mask[dilated_obstacles > 0] = 0

    dist_transform = cv2.distanceTransform(
        walkable_mask,
        cv2.DIST_L2,
        3,
    )

    all_paths, directions, split_is_close = find_all_walkable_paths(
        walkable_mask,
        dist_transform,
    )

    walkable_full = cv2.resize(
        walkable_mask,
        (w_port, h_port),
        interpolation=cv2.INTER_NEAREST,
    ) > 0

    if obstacle_overlay_mask.any():
        composite_frame[obstacle_overlay_mask] = (
            composite_frame[obstacle_overlay_mask] * 0.55
            + np.array([0, 80, 255], dtype=np.uint8) * 0.45
        ).astype(np.uint8)

    if walkable_full.any():
        ground_only = walkable_full & ~obstacle_overlay_mask
        if ground_only.any():
            composite_frame[ground_only] = (
                composite_frame[ground_only] * 0.65
                + np.array([0, 200, 50], dtype=np.uint8) * 0.35
            ).astype(np.uint8)

    if all_paths:
        all_paths[0] = smooth_primary_path(
            all_paths[0],
            PREV_PRIMARY_PATH,
        )
        PREV_PRIMARY_PATH = all_paths[0]

        draw_paths_overlay(composite_frame, all_paths, scale_x, scale_y)

        if len(all_paths) > 1:
            announce_intersection_if_needed(directions, split_is_close)
    else:
        PREV_PRIMARY_PATH = None

    if len(all_obstacles) >= MANY_OBSTACLES_THRESHOLD:
        announce_obstacles_if_needed(all_obstacles, w_port)
    else:
        trigger_obstacle_warning_audio(closest_obstacle, w_port)

    ok, encoded_img = cv2.imencode(
        ".jpg",
        composite_frame,
        [int(cv2.IMWRITE_JPEG_QUALITY), JPEG_QUALITY],
    )
    if not ok:
        return None

    base64_frame = base64.b64encode(encoded_img).decode("ascii")
    total_latency_ms = (time.perf_counter() - frame_start) * 1000.0
    fps = 1000.0 / total_latency_ms if total_latency_ms > 0 else 0.0

    return {
        "status": "success",
        "mask": base64_frame,
        "fps": round(fps, 1),
        "latency_ms": round(total_latency_ms, 1),
    }


# ASYNC WEBSOCKET SERVER
async def process_frame(websocket):
    global PREV_PRIMARY_PATH
    global LAST_AUDIO_TIME
    global LAST_INTERSECTION_ANNOUNCED
    global LAST_OBSTACLE_ANNOUNCEMENT
    global CACHED_GROUND_MASK_SMALL
    global CACHED_YOLO
    global CACHED_YOLO_TIME

    PREV_PRIMARY_PATH = None
    LAST_AUDIO_TIME = 0.0
    LAST_INTERSECTION_ANNOUNCED = ""
    LAST_OBSTACLE_ANNOUNCEMENT = ""
    CACHED_GROUND_MASK_SMALL = None
    CACHED_YOLO = None
    CACHED_YOLO_TIME = 0.0

    frame_queue = asyncio.Queue(maxsize=1)

    async def receiver():
        try:
            async for message in websocket:
                if frame_queue.full():
                    try:
                        frame_queue.get_nowait()
                        frame_queue.task_done()
                    except asyncio.QueueEmpty:
                        pass
                await frame_queue.put(message)
        except Exception:
            pass

    receiver_task = asyncio.create_task(receiver())
    print("📱 Client Connected! (HIGH-FPS Ground-Truth Panoptic mode active)")

    try:
        while True:
            message = await frame_queue.get()
            try:
                data = json.loads(message)
            except Exception:
                frame_queue.task_done()
                continue

            payload = await asyncio.to_thread(process_single_frame, data)
            frame_queue.task_done()

            if payload is not None:
                try:
                    await asyncio.wait_for(
                        websocket.send(json.dumps(payload)),
                        timeout=0.25,
                    )
                except asyncio.TimeoutError:
                    pass

    except (
        websockets.exceptions.ConnectionClosedError,
        websockets.exceptions.ConnectionClosedOK,
    ):
        print("📱 Client Disconnected.")
    except Exception as exc:
        print(f"⚠️ Client handler error: {exc}")
    finally:
        receiver_task.cancel()
        PREV_PRIMARY_PATH = None
        CACHED_GROUND_MASK_SMALL = None
        CACHED_YOLO = None


async def main():
    async with websockets.serve(
        process_frame,
        "0.0.0.0",
        8765,
        max_size=8 * 1024 * 1024,
        compression=None,
        ping_interval=20,
        ping_timeout=10,
    ):
        print("⚡ Ground-Truth Panoptic Server active on ws://0.0.0.0:8765")
        await asyncio.Future()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    finally:
        try:
            pygame.mixer.quit()
        except Exception:
            pass
