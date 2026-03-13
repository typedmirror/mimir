from typing import assert_type, Optional

class Token:
    text: str
    def __init__(self, text: str):
        self.text = text

# Function returning Optional[Class]
def find_token(s: str) -> Optional[Token]:
    if len(s) > 0:
        return Token(s)
    return None
