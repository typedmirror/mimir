"""Sample test file with bare test_* functions and TestCase classes."""
import unittest


# Bare test functions (pytest-style)
def test_add():
    assert 1 + 1 == 2

def test_string():
    assert "hello".upper() == "HELLO"

def test_fail():
    assert 1 + 1 == 3, "math is broken"

def not_a_test():
    """Should NOT be discovered."""
    pass


# unittest.TestCase class
class TestMath(unittest.TestCase):
    def test_multiply(self):
        self.assertEqual(2 * 3, 6)

    def test_div_zero(self):
        with self.assertRaises(ZeroDivisionError):
            1 / 0


class TestSkip(unittest.TestCase):
    @unittest.skip("not ready yet")
    def test_future(self):
        pass
