# Python fixtures that SHOULD trigger a condition-order diagnostic.

import re

# Expensive call before cheap variable — should warn
def check_admin(user, is_enabled):
    if re.match(r"admin", user.name) and is_enabled:
        pass

# Method call before identifier — should warn
def check_status(obj, active):
    if obj.expensive_method() and active:
        pass

# Nested expensive call before bool literal — should warn
def nested(flag, name):
    if re.search(r"pattern", name) and flag:
        pass
