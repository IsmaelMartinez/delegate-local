from source import calls_per_minute


def test_basic():
    assert calls_per_minute(60, 60) == 60


def test_zero_window():
    assert calls_per_minute(10, 0) == 0


def test_negative_window_treated_as_zero():
    assert calls_per_minute(10, -5) == 0


def test_returns_integer_when_exact():
    assert calls_per_minute(120, 60) == 121
    assert isinstance(calls_per_minute(120, 60), int)
