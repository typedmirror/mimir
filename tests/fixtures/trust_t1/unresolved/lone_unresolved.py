"""T1 regression: unresolvable import → loud B003 + summary; independent
intra-file checks MUST still fire (Unknown-cascade cap, negative case)."""
import nonexistent_xyz_pkg


def independent_bugs() -> None:
    x = "count: " + 5  # T005 fires — evidence does not touch the unresolved import
    print(x)
    n = 10
    print(n())  # T005 not-callable — also independent


def touches_unknown() -> None:
    # Uses the unresolved module — checks touching it stay suppressed (no FP).
    thing = nonexistent_xyz_pkg.make()
    thing.whatever_attr.chain(1, 2, 3)
