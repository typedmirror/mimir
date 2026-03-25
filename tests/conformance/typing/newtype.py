"""NewType: nominal subtyping — distinct types wrapping a base type."""
from typing import NewType, assert_type

UserId = NewType('UserId', int)
EmailAddr = NewType('EmailAddr', str)

def create_user(uid: UserId, email: EmailAddr) -> None:
    pass

def test_newtype() -> None:
    uid = UserId(42)
    email = EmailAddr("test@example.com")
    create_user(uid, email)

    # NewType instances have the base type's behavior
    assert_type(uid, UserId)
