def calls_per_minute(calls, window_seconds):
    if window_seconds <= 0:
        return 0
    return calls / window_seconds * 60
