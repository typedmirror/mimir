from abc import ABC, abstractmethod

class Abstract(ABC):
    @abstractmethod
    def unimplemented(self) -> None: ...

# T013: Cannot instantiate abstract class
x = Abstract()  # E[T013]: unimplemented abstract method(s)
