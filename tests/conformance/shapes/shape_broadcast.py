"""Shape validation: numpy-compatible broadcasting rules."""

from mimir.array import zeros

# Valid broadcasts
a = zeros((3, 4))
b = zeros((4,))
c = a + b             # OK: (3,4) + (4,) -> (3,4)

d = zeros((1, 4))
e = a + d             # OK: (3,4) + (1,4) -> (3,4)

# Invalid broadcast — incompatible dimensions
f = zeros((5,))
g = a + f             # E[S002]: cannot broadcast (3,4) and (5,)

h = zeros((3, 5))
i = a + h             # E[S002]: cannot broadcast (3,4) and (3,5)

# Pow (**) — System B (constraints.odin) only collects Shape_Broadcast
# constraints for Add/Sub/Mult/Div, not Pow/Mod/Floor_Div. SHAPE003
# (System A) fires here uncontested: the D3 double-emit guard has nothing
# to suppress against, since S002 never fires for this op.
j = zeros((3, 5))
k = a ** j            # E[SHAPE003]: cannot broadcast (3,4) and (3,5)
