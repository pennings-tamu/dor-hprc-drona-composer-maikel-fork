#!/usr/bin/env python3
"""Where shared runtime_support files live.

No dependencies outside the standard library, so the app (views), the engine and
retriever scripts can all import it. It answers two questions:

- find_retriever(name): which file runs for a retriever name. Search order:
  schedulers/<scheduler>/retrievers/ -> retrievers/.
  (The environment's own directory is searched before this, by the caller.)
- scheduler_dir(): where the active scheduler's files live.

The scheduler is DRONA_SCHEDULER (set by the app from "scheduler" in
config.yml), default "slurm".
"""
import os
import re

RUNTIME_DIR = os.path.dirname(os.path.abspath(__file__))


def scheduler_name():
    name = (os.environ.get("DRONA_SCHEDULER") or "slurm").strip().lower()
    return name if re.fullmatch(r"\w+", name) else "slurm"


def scheduler_dir(name=None):
    return os.path.join(RUNTIME_DIR, "schedulers", name or scheduler_name())


def retriever_dirs():
    return [
        os.path.join(scheduler_dir(), "retrievers"),
        os.path.join(RUNTIME_DIR, "retrievers"),
    ]


def find_retriever(name):
    """Full path of a shared retriever, or None. name may contain subdirectories
    but must stay inside the search directories."""
    if not name or os.path.isabs(name):
        return None
    for base in retriever_dirs():
        path = os.path.normpath(os.path.join(base, name))
        if path.startswith(base + os.sep) and os.path.isfile(path):
            return path
    return None

