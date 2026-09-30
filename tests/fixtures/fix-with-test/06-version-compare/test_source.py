from source import version_gt


def test_numeric():
    assert version_gt("1.2.10", "1.2.9")


def test_equal():
    assert not version_gt("1.0", "1.0")


def test_major():
    assert version_gt("2.0", "1.9")
