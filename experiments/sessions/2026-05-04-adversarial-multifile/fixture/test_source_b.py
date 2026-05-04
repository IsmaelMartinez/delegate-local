from source import calls_per_minute


def test_off_by_one_when_exact():
    assert calls_per_minute(120, 60) == 121
