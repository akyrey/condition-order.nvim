package main

import "strings"

func example(enabled bool, name string) {
	// SHOULD flag: expensive call before cheap variable
	if strings.Contains(name, "admin") && enabled {
		println("yes")
	}

	// SHOULD NOT flag: already correct
	if enabled && strings.Contains(name, "admin") {
		println("yes")
	}
}
