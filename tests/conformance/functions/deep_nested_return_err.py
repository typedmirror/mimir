from typing import assert_type

# Return type error in deeply nested function
def level1():
    def level2():
        def level3() -> int:
            return "not int"  # E[T003]
        return level3()
    return level2()
