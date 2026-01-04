"""IPC publisher for sending perception frames to Ruby core."""

import socket
import os
import msgpack
import time
from typing import Dict, Any, Optional
from dataclasses import dataclass


@dataclass
class PublisherStats:
    """Statistics for the publisher."""
    frames_sent: int = 0
    bytes_sent: int = 0
    last_send_time: float = 0.0
    connection_errors: int = 0


class PerceptionPublisher:
    """
    Publishes perception frames over Unix domain socket.
    
    Protocol: Length-prefixed MessagePack
    - 4 bytes: message length (big-endian)
    - N bytes: MessagePack payload
    """
    
    def __init__(self, socket_path: str):
        self.socket_path = socket_path
        self.sock: Optional[socket.socket] = None
        self.stats = PublisherStats()
        self._connected = False
    
    def start(self) -> bool:
        """Create and bind the Unix socket server."""
        # Remove existing socket file if present
        if os.path.exists(self.socket_path):
            os.unlink(self.socket_path)
        
        try:
            self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            self.sock.bind(self.socket_path)
            self.sock.listen(1)
            self.sock.setblocking(True)
            
            print(f"Perception publisher listening on {self.socket_path}")
            return True
        except Exception as e:
            print(f"Failed to start publisher: {e}")
            return False
    
    def wait_for_connection(self, timeout: Optional[float] = None) -> bool:
        """Wait for Ruby core to connect."""
        if self.sock is None:
            return False
        
        print("Waiting for Ruby core to connect...")
        
        if timeout:
            self.sock.settimeout(timeout)
        
        try:
            self.conn, self.addr = self.sock.accept()
            self.conn.setblocking(True)
            self._connected = True
            print("Ruby core connected!")
            return True
        except socket.timeout:
            print("Connection timeout")
            return False
        except Exception as e:
            print(f"Connection error: {e}")
            return False
    
    def publish(self, frame_data: Dict[str, Any]) -> bool:
        """Publish a perception frame."""
        if not self._connected:
            return False
        
        try:
            packed = msgpack.packb(frame_data, use_bin_type=True)
            length = len(packed)
            
            # Send length prefix (4 bytes, big-endian)
            self.conn.sendall(length.to_bytes(4, 'big'))
            # Send payload
            self.conn.sendall(packed)
            
            self.stats.frames_sent += 1
            self.stats.bytes_sent += 4 + length
            self.stats.last_send_time = time.time()
            
            return True
        except BrokenPipeError:
            print("Connection closed by Ruby core")
            self._connected = False
            return False
        except Exception as e:
            self.stats.connection_errors += 1
            print(f"Publish error: {e}")
            return False
    
    def close(self):
        """Close the publisher and cleanup."""
        if hasattr(self, 'conn') and self.conn:
            try:
                self.conn.close()
            except:
                pass
        
        if self.sock:
            try:
                self.sock.close()
            except:
                pass
        
        # Cleanup socket file
        if os.path.exists(self.socket_path):
            try:
                os.unlink(self.socket_path)
            except:
                pass
        
        self._connected = False
    
    @property
    def is_connected(self) -> bool:
        return self._connected
    
    def __enter__(self):
        self.start()
        return self
    
    def __exit__(self, exc_type, exc_val, exc_tb):
        self.close()
        return False
