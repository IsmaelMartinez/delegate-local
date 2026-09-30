from source import last_n


def test_basic():
    assert last_n([1, 2, 3, 4], 2) == [3, 4]


def test_n_zero():
    assert last_n([1, 2, 3], 0) == []
