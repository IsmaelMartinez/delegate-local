from source import rng


def test_inclusive():
    assert rng(1, 3) == [1, 2, 3]


def test_single():
    assert rng(5, 5) == [5]
