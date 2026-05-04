import pytest

from source import clamp, normalise_range


def test_clamp_within_bounds():
    assert clamp(5, 0, 10) == 5


def test_clamp_below():
    assert clamp(-1, 0, 10) == 0


def test_clamp_above():
    assert clamp(99, 0, 10) == 10


def test_clamp_inverted_bounds_raises():
    with pytest.raises(ValueError):
        clamp(5, 10, 0)


def test_normalise_range_orders_ascending():
    assert normalise_range(7, 3) == (3, 7)
    assert normalise_range(3, 7) == (3, 7)
