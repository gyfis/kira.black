# Kira

**An AI that perceives.** Unlike chatbots that wait for you to type, Kira sees through your camera, hears through your microphone, and decides when to speak up.

Built on [OpenCode](https://opencode.ai). Extensible by design.

## How It Works

```
┌─────────────────────────────────────────────────────────────────┐
│                         KIRA CORE                                │
│                                                                  │
│   Senses ──▶ Priority Queue ──▶ Orchestrator ──▶ Response       │
│                                       │                          │
│                                  OpenCode                        │
│                                  (brain)                         │
│                                       │                          │
│                                  TTS Output                      │
└─────────────────────────────────────────────────────────────────┘
        ▲                                               │
   ┌────┴────┐                                    ┌─────┴─────┐
   │ SENSES  │                                    │  OUTPUTS  │
   │ (input) │                                    │           │
   ├─────────┤                                    ├───────────┤
   │ vision  │  ◀── swappable                     │ voice     │
   │ hearing │  ◀── swappable                     │           │
   │ screen  │  ◀── addable                       │           │
   └─────────┘                                    └───────────┘
```

The **loop** is the product. Senses and outputs are **plugins**.

## Quick Start

```bash
# Clone
git clone https://github.com/gyfis/kira.black.git
cd kira.black

# Install Ruby dependencies
cd kira/core
bundle install

# Install Python dependencies
cd ../senses
pip install -e ".[all]"

# Run
cd ../core
bundle exec bin/kira
```

## Requirements

- macOS with Apple Silicon (M1/M2/M3/M4)
- Ruby 3.2+
- Python 3.10+
- [OpenCode](https://opencode.ai) installed and configured
- Camera and microphone access

## Architecture

Kira is a thin orchestration layer on top of OpenCode:

- **OpenCode** = brain (chat, memory, model selection, MCP tools)
- **Kira** = eyes, ears, mouth (vision, hearing, speech)

### The Protocol

Senses communicate with the Ruby core via JSON lines on stdin/stdout:

```json
{"type": "signal", "sense": "hearing", "content": "Hello Kira", "priority": 100}
{"type": "status", "sense": "vision", "status": "ready"}
{"command": "speak", "options": {"text": "Hi there!"}}
```

### Built-in Senses

| Sense | Description | Priority |
|-------|-------------|----------|
| `hearing` | Microphone → Whisper STT | 100 (highest) |
| `vision` | Camera → Moondream VLM | 30 |
| `screen` | Screenshots → VLM | 50 |

### Built-in Outputs

| Output | Description |
|--------|-------------|
| `voice` | Piper TTS (local, fast) |

## Extending Kira

### Add a New Sense

```python
# senses/my_sense/sense.py
from base import BaseSense

class MySense(BaseSense):
    name = "my_sense"
    default_priority = 50
    
    def _initialize(self):
        # Load models
        pass
    
    def _start(self):
        # Start perception loop
        pass
    
    def _stop(self):
        # Stop loop
        pass
```

### Swap an Implementation

Replace the default TTS with ElevenLabs:

```python
# In voice/output.py, change:
from tts.piper import PiperTTS
# to:
from examples.elevenlabs_voice.tts import ElevenLabsTTS as PiperTTS
```

See `examples/` for more.

## Project Structure

```
kira/
├── core/                    # Ruby - The Loop
│   ├── lib/kira/
│   │   ├── orchestrator.rb  # Main loop
│   │   ├── signal.rb        # Signal abstraction
│   │   ├── signal_queue.rb  # Priority queue
│   │   └── sense_manager.rb # Process management
│   └── bin/kira             # Entry point
│
├── senses/                  # Python - Pluggable Modules
│   ├── protocol.py          # The stable contract
│   ├── base.py              # BaseSense, BaseOutput
│   ├── vision/              # Camera + VLM
│   ├── hearing/             # Microphone + STT
│   ├── screen/              # Screenshots + VLM
│   └── voice/               # TTS output
│
└── examples/                # Extension examples
    └── elevenlabs_voice/    # Cloud TTS alternative
```

## Configuration

Kira uses OpenCode for LLM access. Make sure OpenCode is configured:

```bash
opencode config
```

Start Kira with a persona:

```bash
bundle exec bin/kira --persona "friendly engineering partner"
```

Or without camera (voice only):

```bash
bundle exec bin/kira --no-camera
```

## License

MIT License - see [LICENSE](LICENSE)

## Links

- [OpenCode](https://opencode.ai) - The AI coding assistant Kira is built on
- [kira.black](https://kira.black) - Project homepage (coming soon)
