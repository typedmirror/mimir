from typing import assert_type

class Score:
    value: int
    def __init__(self, value: int):
        self.value = value

# Dict with class instances as values
def make_scores() -> dict[str, Score]:
    scores = {"alice": Score(100), "bob": Score(90)}
    assert_type(scores, dict[str, Score])
    return scores
