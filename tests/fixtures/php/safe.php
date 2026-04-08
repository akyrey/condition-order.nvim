<?php
// SHOULD NOT auto-fix: side-effecting call being moved earlier would change behaviour
if (createUser() && sendEmail()) {
    echo "done";
}

// SHOULD NOT auto-fix: null guard — $obj->method() must stay after null check
if ($obj !== null && $obj->method()) {
    echo "ok";
}

// SHOULD NOT auto-fix: ignore comment
if ($expensive->call() && $cheap) { // condition-order: ignore
    echo "ignored";
}
