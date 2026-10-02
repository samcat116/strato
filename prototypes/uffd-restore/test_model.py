import unittest
from hashlib import sha256
from model import Base, Session, select_backend

class Contracts(unittest.TestCase):
    def setUp(self):
        self.data = b'a' * 4096 + b'b' * 4096
        self.base = Base(sha256(self.data).hexdigest(), 'disposable-fixture', self.data)

    def test_digest_and_immutable_input(self):
        with self.assertRaises(ValueError):
            Base('0' * 64, 'fixture', self.data)
        with self.assertRaises(ValueError):
            Base(sha256(self.data).hexdigest(), 'fixture', bytearray(self.data))

    def test_private_dirty_pages(self):
        a, b = Session(self.base, self.base.trust_class), Session(self.base, self.base.trust_class)
        dirty = bytearray(b's' * 4096)
        a.write(0, dirty)
        dirty[0] = 0
        a.request(0); b.request(0)
        self.assertEqual(a.serve(), b's' * 4096)
        self.assertEqual(b.serve(), b'a' * 4096)
        self.assertEqual(self.base.data, self.data)

    def test_trust_gate(self):
        with self.assertRaises(ValueError):
            Session(self.base, 'other-tenant')

    def test_bounds(self):
        a = Session(self.base, self.base.trust_class)
        for page in (-1, 2, True):
            with self.assertRaises(ValueError): a.request(page)
        with self.assertRaises(ValueError): a.write(0, b'short')

    def test_queue_failure_is_local(self):
        a = Session(self.base, self.base.trust_class, capacity=1)
        b = Session(self.base, self.base.trust_class)
        a.request(0)
        with self.assertRaises(RuntimeError): a.request(1)
        with self.assertRaises(RuntimeError): a.serve()
        b.request(1)
        self.assertEqual(b.serve(), b'b' * 4096)

    def test_deadline_and_cancellation(self):
        now = [0]
        a = Session(self.base, self.base.trust_class, clock=lambda: now[0])
        a.request(0); now[0] = 1
        with self.assertRaises(TimeoutError): a.serve()
        with self.assertRaises(RuntimeError): a.request(0)
        b = Session(self.base, self.base.trust_class)
        b.write(0, b's' * 4096); b.request(0); b.cancel()
        with self.assertRaises(RuntimeError): b.serve()
        fresh = Session(self.base, self.base.trust_class)
        fresh.request(0)
        self.assertEqual(fresh.serve(), b'a' * 4096)

    def test_fallback_requires_both_gates(self):
        for proof, lifecycle in ((False, False), (True, False), (False, True)):
            self.assertEqual(select_backend(proof, lifecycle), 'File')

if __name__ == '__main__': unittest.main()
