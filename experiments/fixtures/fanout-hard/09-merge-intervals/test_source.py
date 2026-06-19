from source import merge


def test_unsorted():
    assert merge([(1, 3), (6, 9), (2, 5)]) == [(1, 5), (6, 9)]


def test_disjoint():
    assert merge([(1, 2), (4, 5)]) == [(1, 2), (4, 5)]
