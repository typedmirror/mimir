class Counter:
    count: int

    def get_count(self) -> int:
        return self.count

    def bad_return(self) -> str:
        return self.count  # E
