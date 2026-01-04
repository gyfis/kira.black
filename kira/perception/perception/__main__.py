"""Main entry point for the Kira perception service."""

import argparse
import signal
import sys
import time
from typing import Optional

from .config import PerceptionConfig, CameraConfig, ModelConfig
from .capture import CameraCapture
from .inference import PerceptionModels
from .publisher import PerceptionPublisher


class PerceptionService:
    """Main perception service orchestrator."""
    
    def __init__(self, config: PerceptionConfig):
        self.config = config
        self.camera: Optional[CameraCapture] = None
        self.models: Optional[PerceptionModels] = None
        self.publisher: Optional[PerceptionPublisher] = None
        self._running = False
        self._frame_drop_count = 0
    
    def start(self):
        """Initialize and start the perception pipeline."""
        print("=" * 60)
        print("Kira Perception Service")
        print("=" * 60)
        
        # Initialize components
        self.camera = CameraCapture(self.config.camera)
        self.models = PerceptionModels(self.config.models)
        self.publisher = PerceptionPublisher(self.config.socket_path)
        
        # Start publisher socket
        if not self.publisher.start():
            print("Failed to start publisher socket")
            return False
        
        # Open camera
        if not self.camera.open():
            print("Failed to open camera")
            return False
        
        # Load models (can take a few seconds)
        self.models.load()
        
        # Wait for Ruby core to connect
        if not self.publisher.wait_for_connection(timeout=60.0):
            print("Ruby core did not connect within timeout")
            return False
        
        self._running = True
        return True
    
    def run(self):
        """Main perception loop."""
        if not self._running:
            if not self.start():
                return
        
        target_interval = 1.0 / self.config.camera.fps
        last_stats_time = time.time()
        frames_since_stats = 0
        
        print(f"\nRunning perception at {self.config.camera.fps} FPS...")
        print("Press Ctrl+C to stop\n")
        
        try:
            while self._running:
                loop_start = time.perf_counter()
                
                # Capture frame
                frame = self.camera.read()
                if frame is None:
                    self._frame_drop_count += 1
                    continue
                
                # Run inference
                result = self.models.process(frame.image)
                
                # Build payload
                payload = {
                    "frame_id": frame.frame_id,
                    "timestamp_ms": frame.timestamp_ms,
                    "detections": self.models.to_dict(result)["detections"],
                    "poses": self.models.to_dict(result)["poses"],
                    "metadata": {
                        "capture_latency_ms": frame.capture_latency_ms,
                        "inference_latency_ms": result.inference_latency_ms,
                        "frame_drop_count": self._frame_drop_count,
                        "width": frame.width,
                        "height": frame.height,
                    }
                }
                
                # Publish to Ruby
                if not self.publisher.publish(payload):
                    print("Failed to publish, Ruby core may have disconnected")
                    break
                
                frames_since_stats += 1
                
                # Print stats every 5 seconds
                now = time.time()
                if now - last_stats_time >= 5.0:
                    fps = frames_since_stats / (now - last_stats_time)
                    total_latency = frame.capture_latency_ms + result.inference_latency_ms
                    det_count = len(result.detections)
                    pose_count = len(result.poses)
                    
                    print(f"FPS: {fps:.1f} | Latency: {total_latency:.1f}ms | "
                          f"Detections: {det_count} | Poses: {pose_count} | "
                          f"Frames: {self.publisher.stats.frames_sent}")
                    
                    last_stats_time = now
                    frames_since_stats = 0
                
                # Rate limiting
                elapsed = time.perf_counter() - loop_start
                if elapsed < target_interval:
                    time.sleep(target_interval - elapsed)
        
        except KeyboardInterrupt:
            print("\nShutting down...")
        finally:
            self.stop()
    
    def stop(self):
        """Stop the perception service."""
        self._running = False
        
        if self.camera:
            self.camera.release()
        
        if self.publisher:
            self.publisher.close()
        
        print("Perception service stopped")
        print(f"Total frames sent: {self.publisher.stats.frames_sent if self.publisher else 0}")


def main():
    parser = argparse.ArgumentParser(description="Kira Perception Service")
    parser.add_argument("--socket", default="/tmp/kira.sock",
                        help="Unix socket path (default: /tmp/kira.sock)")
    parser.add_argument("--fps", type=int, default=30,
                        help="Target FPS (default: 30)")
    parser.add_argument("--width", type=int, default=1280,
                        help="Camera width (default: 1280)")
    parser.add_argument("--height", type=int, default=720,
                        help="Camera height (default: 720)")
    parser.add_argument("--device", type=int, default=0,
                        help="Camera device ID (default: 0)")
    parser.add_argument("--no-pose", action="store_true",
                        help="Disable pose estimation")
    parser.add_argument("--no-detection", action="store_true",
                        help="Disable object detection")
    
    args = parser.parse_args()
    
    config = PerceptionConfig(
        socket_path=args.socket,
        camera=CameraConfig(
            device_id=args.device,
            width=args.width,
            height=args.height,
            fps=args.fps,
        ),
        models=ModelConfig(
            object_detection=not args.no_detection,
            pose_estimation=not args.no_pose,
        ),
    )
    
    service = PerceptionService(config)
    
    # Handle signals gracefully
    def signal_handler(sig, frame):
        print("\nReceived signal, shutting down...")
        service.stop()
        sys.exit(0)
    
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)
    
    service.run()


if __name__ == "__main__":
    main()
