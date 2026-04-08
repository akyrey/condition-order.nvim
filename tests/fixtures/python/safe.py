# Python fixtures that should NOT trigger any condition-order diagnostic.

import re

# Correct order: cheap before expensive
def check_admin_safe(is_enabled, user):
    if is_enabled and re.match(r"admin", user.name):
        pass

# Null guard: must not be reordered past the access it protects
def check_nullable(obj):
    if obj is not None and obj.active:
        pass

# Side-effecting calls: fix should be blocked (diagnostic may fire, but no fix)
def with_side_effects():
    with open("file.txt") as f:
        data = f.read()
    return data

# Already correct order
def already_ordered(flag, name):
    if flag and re.search(r"pattern", name):
        pass
