"""
Moondream VLM Service for Kira.

Provides local vision-language understanding using Moondream2.
Runs at 2Hz to provide scene descriptions.
"""

import sys
import json
import time
import threading
import queue
from dataclasses import dataclass
from typing import Optional
import numpy as np

# Lazy imports
_model = None
_tokenizer = None
_model_lock = threading.Lock()


def get_model():
    """Lazy load the Moondream model."""
    global _model, _tokenizer
    if _model is None:
        with _model_lock:
            if _model is None:
                print("Loading Moondream2 model...", file=sys.stderr)
                
                import torch
                from transformers import AutoModelForCausalLM, AutoTokenizer
                
                model_id = "vikhyatk/moondream2"
                revision = "2025-01-09"
                
                # Use MPS (Apple Silicon GPU) if available for ~6x speedup
                device = "mps" if torch.backends.mps.is_available() else "cpu"
                dtype = torch.float16 if device == "mps" else torch.float32
                
                _tokenizer = AutoTokenizer.from_pretrained(
                    model_id, revision=revision, local_files_only=True
                )
                _model = AutoModelForCausalLM.from_pretrained(
                    model_id,
                    revision=revision,
                    trust_remote_code=True,
                    torch_dtype=dtype,
                    local_files_only=True,
                ).to(device)
                
                print(f"Moondream2 loaded on {device}", file=sys.stderr)
    return _model, _tokenizer


@dataclass
class SceneDescription:
    description: str
    timestamp: float
    inference_ms: int


class MoondreamVLM:
    """Scene understanding using Moondream2."""
    
    DEFAULT_PROMPT = "Describe what you see in this image. Focus on any people, their expressions, posture, and what they appear to be doing."
    
    def __init__(self, prompt: Optional[str] = None):
        self.prompt = prompt or self.DEFAULT_PROMPT
        self._last_description = None
        self._last_description_time = 0
        
    def describe(self, image: np.ndarray) -> Optional[SceneDescription]:
        """
        Generate a description of the scene.
        
        Args:
            image: RGB image as numpy array (H, W, 3)
            
        Returns:
            SceneDescription with the description text, or None on error.
        """
        try:
            from PIL import Image
            
            # Validate image
            if image is None or image.size == 0:
                print("Empty image provided", file=sys.stderr)
                return None
            
            if len(image.shape) != 3 or image.shape[2] != 3:
                print(f"Invalid image shape: {image.shape}, expected (H, W, 3)", file=sys.stderr)
                return None
            
            model, tokenizer = get_model()
            
            # Convert numpy to PIL
            pil_image = Image.fromarray(image)
            
            t0 = time.time()
            
            # Encode image
            enc_image = model.encode_image(pil_image)
            
            # Generate description
            description = model.answer_question(enc_image, self.prompt, tokenizer)
            
            inference_ms = int((time.time() - t0) * 1000)
            
            result = SceneDescription(
                description=description.strip(),
                timestamp=time.time(),
                inference_ms=inference_ms
            )
            
            self._last_description = result
            self._last_description_time = time.time()
            
            return result
            
        except Exception as e:
            print(f"VLM describe error: {e}", file=sys.stderr)
            return None
    
    def has_changed(self, new_description: str, threshold: float = 0.3) -> bool:
        """Check if the scene has meaningfully changed from the last description."""
        if self._last_description is None:
            return True
            
        # Simple heuristic: check word overlap
        old_words = set(self._last_description.description.lower().split())
        new_words = set(new_description.lower().split())
        
        if not old_words or not new_words:
            return True
            
        overlap = len(old_words & new_words) / max(len(old_words), len(new_words))
        return overlap < (1 - threshold)


class VLMService:
    """Service that runs VLM at specified Hz on camera frames."""
    
    def __init__(self, hz: float = 2.0, prompt: Optional[str] = None):
        self.hz = hz
        self.interval = 1.0 / hz
        self.vlm = MoondreamVLM(prompt=prompt)
        self._running = False
        self._frame_queue = queue.Queue(maxsize=1)  # Only keep latest frame
        self._callbacks = []
        
    def on_description(self, callback):
        """Register callback for new descriptions."""
        self._callbacks.append(callback)
        
    def submit_frame(self, frame: np.ndarray):
        """Submit a new frame for processing."""
        try:
            # Replace any existing frame (we only care about the latest)
            try:
                self._frame_queue.get_nowait()
            except queue.Empty:
                pass
            self._frame_queue.put_nowait(frame)
        except queue.Full:
            pass
            
    def start(self):
        """Start the VLM processing loop."""
        self._running = True
        self._thread = threading.Thread(target=self._process_loop, daemon=True)
        self._thread.start()
        print(f"VLM service started at {self.hz}Hz", file=sys.stderr)
        
    def stop(self):
        """Stop the VLM processing loop."""
        self._running = False
        
    def _process_loop(self):
        """Main processing loop."""
        last_process_time = 0
        
        while self._running:
            try:
                frame = self._frame_queue.get(timeout=0.1)
            except queue.Empty:
                continue
                
            # Rate limit
            now = time.time()
            if now - last_process_time < self.interval:
                continue
                
            last_process_time = now
            
            try:
                result = self.vlm.describe(frame)
                
                if result is None:
                    continue
                
                # Check if scene changed meaningfully
                if self.vlm.has_changed(result.description):
                    for callback in self._callbacks:
                        try:
                            callback(result)
                        except Exception as e:
                            print(f"VLM callback error: {e}", file=sys.stderr)
                        
            except Exception as e:
                print(f"VLM error: {e}", file=sys.stderr)


def run_service():
    """Run as a stdin/stdout service."""
    import cv2
    
    vlm = MoondreamVLM()
    
    print(json.dumps({'type': 'ready'}), flush=True)
    
    for line in sys.stdin:
        try:
            request = json.loads(line.strip())
            
            if request.get('command') == 'describe':
                # Expect base64 image or file path
                if 'image_path' in request:
                    image = cv2.imread(request['image_path'])
                    image = cv2.cvtColor(image, cv2.COLOR_BGR2RGB)
                elif 'image_base64' in request:
                    import base64
                    img_data = base64.b64decode(request['image_base64'])
                    nparr = np.frombuffer(img_data, np.uint8)
                    image = cv2.imdecode(nparr, cv2.IMREAD_COLOR)
                    image = cv2.cvtColor(image, cv2.COLOR_BGR2RGB)
                else:
                    print(json.dumps({'type': 'error', 'message': 'No image provided'}), flush=True)
                    continue
                    
                result = vlm.describe(image)
                
                if result is None:
                    print(json.dumps({'type': 'error', 'message': 'Failed to describe image'}), flush=True)
                    continue
                
                print(json.dumps({
                    'type': 'description',
                    'description': result.description,
                    'inference_ms': result.inference_ms
                }), flush=True)
                
            elif request.get('command') == 'stop':
                break
                
        except json.JSONDecodeError as e:
            print(json.dumps({'type': 'error', 'message': str(e)}), flush=True)
        except Exception as e:
            print(json.dumps({'type': 'error', 'message': str(e)}), flush=True)


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == '--test':
        import cv2
        
        # Test with webcam
        vlm = MoondreamVLM()
        cap = cv2.VideoCapture(0)
        
        if cap.isOpened():
            ret, frame = cap.read()
            if ret:
                frame_rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
                result = vlm.describe(frame_rgb)
                if result:
                    print(f"Description: {result.description}")
                    print(f"Inference time: {result.inference_ms}ms")
                else:
                    print("Failed to describe image")
            cap.release()
        else:
            print("Could not open camera")
    else:
        run_service()
