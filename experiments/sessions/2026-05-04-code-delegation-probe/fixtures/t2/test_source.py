import pytest

from source import paginate


ITEMS = list(range(10))


def test_first_page_is_page_one():
    assert paginate(ITEMS, 1, 3) == [0, 1, 2]


def test_second_page_is_page_two():
    assert paginate(ITEMS, 2, 3) == [3, 4, 5]


def test_last_page_partial():
    assert paginate(ITEMS, 4, 3) == [9]


def test_page_zero_raises():
    with pytest.raises(ValueError):
        paginate(ITEMS, 0, 3)


def test_page_beyond_end_returns_empty():
    assert paginate(ITEMS, 99, 3) == []
