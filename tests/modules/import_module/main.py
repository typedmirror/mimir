import utils

x: int = utils.add(1, 2)      # OK — utils.add returns int
y: str = utils.add(1, 2)      # E  — int not assignable to str
z: str = utils.name            # OK — utils.name is str
w: int = utils.name            # E  — str not assignable to int
