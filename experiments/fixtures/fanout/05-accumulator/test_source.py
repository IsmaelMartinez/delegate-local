from source import running_max


def test_increasing():
    assert running_max([3, 1, 4, 1, 5]) == [3, 3, 4, 4, 5]


def test_single():
    assert running_max([7]) == [7]
