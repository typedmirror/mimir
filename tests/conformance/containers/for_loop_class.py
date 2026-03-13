from typing import assert_type

class Task:
    name: str
    done: bool
    def __init__(self, name: str, done: bool):
        self.name = name
        self.done = done

# Iterating over list of class instances in function
def count_done(tasks: list[Task]) -> int:
    count = 0
    for t in tasks:
        assert_type(t, Task)
        if t.done:
            count += 1
    return count
