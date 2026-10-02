"""Isolated contract model, NOT a UFFD handler or production capability."""
from collections import deque
from dataclasses import dataclass
from hashlib import sha256
import time

@dataclass(frozen=True)
class Base:
    digest: str
    trust_class: str
    data: bytes
    page_size: int = 4096

    def __post_init__(self):
        if not isinstance(self.data, bytes) or not self.trust_class:
            raise ValueError("immutable bytes and explicit trust class required")
        if self.page_size <= 0 or len(self.data) % self.page_size:
            raise ValueError("invalid memory layout")
        if sha256(self.data).hexdigest() != self.digest:
            raise ValueError("base digest mismatch")

class Session:
    def __init__(self, base, trust_class, capacity=8, timeout=1, clock=time.monotonic):
        if trust_class != base.trust_class:
            raise ValueError("trust class mismatch")
        if capacity <= 0 or timeout <= 0:
            raise ValueError("positive bounds required")
        self.base, self.capacity, self.timeout, self.clock = base, capacity, timeout, clock
        self._dirty, self._queue, self.closed = {}, deque(), False

    def _check(self, page):
        if self.closed:
            raise RuntimeError("session cancelled or failed")
        if type(page) is not int or not 0 <= page < len(self.base.data) // self.base.page_size:
            raise ValueError("page out of bounds")

    def write(self, page, data):
        self._check(page)
        if len(data) != self.base.page_size:
            raise ValueError("whole page required")
        self._dirty[page] = bytes(data)

    def request(self, page):
        self._check(page)
        if len(self._queue) >= self.capacity:
            self.cancel()
            raise RuntimeError("bounded queue exhausted")
        self._queue.append((page, self.clock() + self.timeout))

    def serve(self):
        if self.closed:
            raise RuntimeError("session cancelled or failed")
        page, deadline = self._queue.popleft()
        if self.clock() >= deadline:
            self.cancel()
            raise TimeoutError("fault deadline exceeded")
        start = page * self.base.page_size
        return self._dirty.get(page, self.base.data[start:start + self.base.page_size])

    def cancel(self):
        self.closed = True
        self._queue.clear()
        self._dirty.clear()

# No model result, version string, or syscall probe can enable lazy restore.
def select_backend(end_to_end_proof=False, lifecycle_ready=False):
    return "Uffd" if end_to_end_proof and lifecycle_ready else "File"
