import os
import time
import numpy as np

# Suppress PyGame startup message
os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame
from scipy.signal import butter, sosfilt

SAMPLE_RATE = 44100
HEAD_RADIUS = 0.0875  # ~8.75 cm average human head radius
SPEED_OF_SOUND = 343.0  # Speed of sound in m/s


def generate_soft_tone(duration=0.10, freq=440.0):
    """
    Generates a warm, organic soft tone (A4 note) with smooth Gaussian 
    shaping to ensure zero harsh clicks during continuous movement.
    """
    t = np.linspace(0, duration, int(SAMPLE_RATE * duration), endpoint=False)
    
    # Fundamental frequency + subtle warm harmonics (exponential decay)
    tone = (
        1.0 * np.sin(2 * np.pi * freq * t) +
        0.2 * np.sin(2 * np.pi * (freq * 2) * t) +
        0.05 * np.sin(2 * np.pi * (freq * 3) * t)
    )
    
    # Smooth Gaussian bell-curve envelope for a soft touch
    center = len(t) / 2
    std_dev = len(t) / 4
    envelope = np.exp(-0.5 * ((np.arange(len(t)) - center) / std_dev) ** 2)
    
    # Scale total volume to a gentle listening level
    return (tone * envelope) * 0.35


def apply_pinna_filter(signal, is_back=False):
    """Simulates outer-ear shadowing by dampening high frequencies when sound is behind."""
    if not is_back:
        return signal
    # Smooth 2.2 kHz low-pass filter for rear positioning
    sos = butter(2, 2200, 'low', fs=SAMPLE_RATE, output='sos')
    return sosfilt(sos, signal)


def spatialize(mono_signal, azimuth_deg):
    """
    Spatialize mono audio onto 2D/3D headphone stereo.
    0° = Front, 90° = Right, 180° = Back, 270° = Left
    """
    rad = np.radians(azimuth_deg % 360)

    # 1. Front vs. Back Pinna Shadowing
    is_back = 90 < (azimuth_deg % 360) < 270
    processed_signal = apply_pinna_filter(mono_signal, is_back=is_back)

    # 2. Interaural Level Difference (ILD)
    pan = (np.sin(rad) + 1) / 2.0  # 0.0 = Left, 0.5 = Center, 1.0 = Right
    gain_l = np.cos(pan * np.pi / 2)
    gain_r = np.sin(pan * np.pi / 2)

    # 3. Interaural Time Difference (ITD)
    delay_sec = (HEAD_RADIUS / SPEED_OF_SOUND) * (
        np.abs(np.sin(rad)) + np.abs(rad % np.pi - np.pi / 2)
    )
    delay_samples = int(delay_sec * SAMPLE_RATE)

    stereo = np.zeros((len(processed_signal) + delay_samples, 2))

    # Apply arrival time delay to the opposing ear
    if np.sin(rad) >= 0:  # Right side
        stereo[: len(processed_signal), 1] = processed_signal * gain_r
        stereo[delay_samples : delay_samples + len(processed_signal), 0] = (
            processed_signal * gain_l
        )
    else:  # Left side
        stereo[: len(processed_signal), 0] = processed_signal * gain_l
        stereo[delay_samples : delay_samples + len(processed_signal), 1] = (
            processed_signal * gain_r
        )

    return stereo


def continuous_360_orbit(rotations=2, speed_deg_per_step=5.0):
    """Smoothly orbits the soft tone 360 degrees around the listener's head."""
    # Initialize PyGame mixer for high quality 16-bit audio
    pygame.mixer.init(frequency=SAMPLE_RATE, size=-16, channels=2, buffer=512)
    
    total_degrees = 360 * rotations
    current_angle = 0.0

    print("Starting Smooth 360° Spatial Orbit... (Put on your headphones!)\n")
    time.sleep(0.5)

    try:
        while current_angle < total_degrees:
            angle = current_angle % 360
            
            # Simple text visual indicator for current position
            if 45 <= angle < 135:
                pos = "RIGHT side"
            elif 135 <= angle < 225:
                pos = "BEHIND you"
            elif 225 <= angle < 315:
                pos = "LEFT side"
            else:
                pos = "IN FRONT"

            print(f"\rOrbiting... Angle: {angle:>5.1f}° | Location: {pos:<12}", end="", flush=True)

            # Generate and spatialize soft tone at the current angle
            mono_tone = generate_soft_tone(duration=0.08, freq=440.0)
            spatial_audio = spatialize(mono_tone, angle)

            # Convert float32 array to 16-bit PCM integer format
            audio_int16 = np.int16(np.clip(spatial_audio, -1.0, 1.0) * 32767)
            
            # Play sound chunk using PyGame
            sound = pygame.sndarray.make_sound(audio_int16)
            sound.play()
            
            # Pacing delay between steps to create smooth movement
            time.sleep(0.04)
            current_angle += speed_deg_per_step

    except KeyboardInterrupt:
        print("\nOrbit stopped by user.")
    finally:
        pygame.mixer.quit()

    print("\n\n360° Orbit Complete!")


if __name__ == "__main__":
    # Run 2 full rotations around the head
    continuous_360_orbit(rotations=2, speed_deg_per_step=4.0)