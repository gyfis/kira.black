"""
Moondream VLM implementation for Kira vision sense.

This is the default VLM that ships with Kira. It uses Moondream2
for fast emotion and activity detection from camera frames.

To swap this for a different VLM, create a new module that exports
FastVLM and HybridVLM classes with the same interface.
"""

import sys
import time
import threading
import numpy as np
from dataclasses import dataclass
from typing import Optional, Tuple
from PIL import Image

_model = None
_tokenizer = None
_model_lock = threading.Lock()

OPTIMAL_SIZE = (320, 240)  # Width, Height - sweet spot for speed/quality


@dataclass
class FastVLMResult:
    """Result from fast VLM analysis."""

    emotion: str
    activity: str
    summary: str
    inference_ms: int


def get_model():
    """Lazy load Moondream model optimized for speed."""
    global _model, _tokenizer
    if _model is None:
        with _model_lock:
            if _model is None:
                print("Loading Moondream2 (fast mode)...", file=sys.stderr)
                import torch
                from transformers import AutoModelForCausalLM, AutoTokenizer

                model_id = "vikhyatk/moondream2"
                revision = "2025-01-09"

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

                print(f"Moondream2 loaded on {device} (fast mode)", file=sys.stderr)
    return _model, _tokenizer


class FastVLM:
    """
    Fast Vision-Language Model for real-time scene understanding.

    Optimizations:
    - Downscales to 320x240 (4x faster)
    - Uses short prompts (2x faster)
    - Focuses on emotion + activity detection

    Target latency: <500ms (vs 5000ms baseline = 10x speedup)
    """

    FAST_PROMPT = (
        "Describe the person's emotion and what they're doing in one sentence."
    )
    EMOTION_PROMPT = "Person emotion in 1 word:"

    def __init__(self, target_size: Tuple[int, int] = OPTIMAL_SIZE):
        self.target_size = target_size
        self._last_result: Optional[FastVLMResult] = None

    def analyze(
        self, frame: np.ndarray, include_activity: bool = True
    ) -> Optional[FastVLMResult]:
        """
        Analyze frame for emotion and activity.

        Args:
            frame: RGB image as numpy array (H, W, 3)
            include_activity: If True, includes activity description (slower)

        Returns:
            FastVLMResult with emotion, activity, and summary
        """
        try:
            import cv2

            t0 = time.time()

            small = cv2.resize(frame, self.target_size)
            pil_img = Image.fromarray(small)

            model, tokenizer = get_model()
            enc = model.encode_image(pil_img)

            if include_activity:
                response = model.answer_question(enc, self.FAST_PROMPT, tokenizer)
                emotion = self._extract_emotion(response)
                activity = response
            else:
                response = model.answer_question(
                    enc, self.EMOTION_PROMPT, tokenizer
                ).strip()
                emotion = response
                activity = ""

            inference_ms = int((time.time() - t0) * 1000)

            result = FastVLMResult(
                emotion=emotion,
                activity=activity,
                summary=response,
                inference_ms=inference_ms,
            )

            self._last_result = result
            return result

        except Exception as e:
            print(f"FastVLM error: {e}", file=sys.stderr)
            return None

    def quick_emotion(self, frame: np.ndarray) -> Tuple[str, int]:
        """Ultra-fast emotion-only detection."""
        result = self.analyze(frame, include_activity=False)
        if result:
            return result.emotion, result.inference_ms
        return "unknown", 0

    def _extract_emotion(self, text: str) -> str:
        """Extract emotion keyword from response."""
        text_lower = text.lower()

        emotions = [
            "happy",
            "sad",
            "angry",
            "surprised",
            "fearful",
            "disgusted",
            "neutral",
            "calm",
            "excited",
            "confused",
            "tired",
            "focused",
            "joyful",
            "anxious",
            "relaxed",
            "bored",
            "curious",
        ]

        for emotion in emotions:
            if emotion in text_lower:
                return emotion

        return "neutral"


class HybridVLM:
    """
    Hybrid approach: Fast analysis + periodic full VLM.

    - Every frame: Fast emotion detection (~400ms)
    - Every N frames: Full scene description (~1500ms)
    """

    def __init__(self, full_analysis_interval: int = 30):
        self.fast_vlm = FastVLM()
        self.full_analysis_interval = full_analysis_interval
        self._frame_count = 0
        self._last_full_analysis: Optional[str] = None

    def analyze(self, frame: np.ndarray) -> dict:
        """
        Analyze frame with hybrid approach.

        Returns dict with:
        - emotion: Current emotion (always fresh)
        - activity: Activity description (may be cached)
        - is_full_analysis: Whether this was a full analysis
        - inference_ms: Time taken
        """
        self._frame_count += 1
        do_full = self._frame_count % self.full_analysis_interval == 0

        result = self.fast_vlm.analyze(frame, include_activity=do_full)

        if result is None:
            return {
                "emotion": "unknown",
                "activity": self._last_full_analysis or "",
                "is_full_analysis": False,
                "inference_ms": 0,
            }

        if do_full:
            self._last_full_analysis = result.activity

        return {
            "emotion": result.emotion,
            "activity": result.activity
            if do_full
            else (self._last_full_analysis or ""),
            "is_full_analysis": do_full,
            "inference_ms": result.inference_ms,
        }
