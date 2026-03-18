# Protocol inference: param with .read() + .close() → structural Protocol
# resource.read() returns str → process() returns str

class FileWrapper:
    def read(self) -> str:
        return "data"
    def close(self) -> None:
        pass

def process(resource):
    data = resource.read()
    resource.close()
    return data

# Protocol synthesized: {read: () → str, close: () → None}
# FileWrapper satisfies it. Return type inferred as str.
result: int = process(FileWrapper())  # E: Incompatible types
