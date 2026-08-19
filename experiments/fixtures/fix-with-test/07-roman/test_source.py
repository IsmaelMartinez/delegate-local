from source import to_roman


def test_four():
    assert to_roman(4) == "IV"


def test_nine():
    assert to_roman(9) == "IX"


def test_big():
    assert to_roman(1994) == "MCMXCIV"
