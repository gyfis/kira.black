#!/usr/bin/env python3
"""Check camera availability and capabilities."""

import sys

def main():
    try:
        import cv2
    except ImportError:
        print("Error: OpenCV not installed")
        print("Run: pip install opencv-python")
        sys.exit(1)
    
    print("Checking camera devices...")
    print()
    
    found_camera = False
    
    for device_id in range(5):
        cap = cv2.VideoCapture(device_id)
        
        if cap.isOpened():
            found_camera = True
            ret, frame = cap.read()
            
            if ret:
                width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
                height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
                fps = cap.get(cv2.CAP_PROP_FPS)
                
                print(f"Device {device_id}: OK")
                print(f"  Resolution: {width}x{height}")
                print(f"  FPS: {fps:.1f}")
                print(f"  Frame shape: {frame.shape}")
            else:
                print(f"Device {device_id}: Opens but cannot read frames")
            
            cap.release()
        else:
            if device_id == 0:
                print(f"Device {device_id}: Not available")
    
    print()
    
    if found_camera:
        print("Camera check: PASSED")
        print()
        print("Kira should be able to access your camera.")
        sys.exit(0)
    else:
        print("Camera check: FAILED")
        print()
        print("No camera devices found. Please check:")
        print("  1. Camera is connected")
        print("  2. Camera permissions are granted in System Preferences")
        print("  3. No other application is using the camera")
        sys.exit(1)

if __name__ == "__main__":
    main()
