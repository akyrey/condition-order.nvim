<?php
// SHOULD flag: expensive before cheap
if ($user->isAdmin() && $isEnabled) {
    echo "yes";
}

// SHOULD flag: method call before variable
$result = ($obj->getResult() && $flag) ? 1 : 0;

// SHOULD NOT flag: already in correct order
if ($isEnabled && $user->isAdmin()) {
    echo "yes";
}

// SHOULD NOT flag: already in correct order (variable then property)
if ($active && $obj->prop) {
    echo "yes";
}
