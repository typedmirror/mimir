"""Smoke test: REST API server with type-safe request/response handling.
Tests: TypedDict validation, Optional narrowing, error handling patterns,
serialization checks, generic response types.
"""
from typing import TypedDict, Optional, Generic, TypeVar, List, Union, Literal

T = TypeVar('T')

# ---- Request/Response types ----

class UserCreate(TypedDict):
    username: str
    email: str
    age: int

class UserResponse(TypedDict):
    id: int
    username: str
    email: str

class ErrorResponse(TypedDict):
    error: str
    code: int

class PaginatedResponse(TypedDict):
    items: list
    total: int
    page: int
    per_page: int

# ---- Validation ----

def validate_email(email: str) -> bool:
    return "@" in email and "." in email

def validate_user(data: UserCreate) -> Optional[str]:
    if len(data["username"]) < 3:
        return "username too short"
    if not validate_email(data["email"]):
        return "invalid email"
    if data["age"] < 0 or data["age"] > 150:
        return "invalid age"
    return None

# ---- Storage ----

class InMemoryDB:
    def __init__(self) -> None:
        self.users: List[UserResponse] = []
        self.next_id: int = 1

    def create_user(self, data: UserCreate) -> UserResponse:
        user: UserResponse = {
            "id": self.next_id,
            "username": data["username"],
            "email": data["email"],
        }
        self.users.append(user)
        self.next_id += 1
        return user

    def get_user(self, user_id: int) -> Optional[UserResponse]:
        for user in self.users:
            if user["id"] == user_id:
                return user
        return None

    def list_users(self, page: int = 1, per_page: int = 10) -> PaginatedResponse:
        start = (page - 1) * per_page
        end = start + per_page
        items = self.users[start:end]
        return {
            "items": items,
            "total": len(self.users),
            "page": page,
            "per_page": per_page,
        }

# ---- Handlers ----

def handle_create_user(
    db: InMemoryDB,
    data: UserCreate,
) -> Union[UserResponse, ErrorResponse]:
    error = validate_user(data)
    if error is not None:
        return {"error": error, "code": 400}
    return db.create_user(data)

def handle_get_user(
    db: InMemoryDB,
    user_id: int,
) -> Union[UserResponse, ErrorResponse]:
    user = db.get_user(user_id)
    if user is None:
        return {"error": "user not found", "code": 404}
    return user

# ---- Main ----

def main() -> None:
    db = InMemoryDB()

    result = handle_create_user(db, {
        "username": "alice",
        "email": "alice@example.com",
        "age": 30,
    })

    user = handle_get_user(db, 1)
    page = db.list_users(page=1, per_page=5)

if __name__ == "__main__":
    main()
