import multiprocessing
from typing import Any


def main():
    pool: Any = multiprocessing.Pool(4)

    # PROC002: lambda cannot be pickled for multiprocessing
    _ = pool.map(lambda x: x * 2, [1, 2, 3])  # E[PROC002]: lambda cannot be pickled

    pool.close()
    pool.join()


if __name__ == '__main__':
    main()
