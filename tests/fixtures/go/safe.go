package main

func safeExamples(obj *MyStruct, err error) {
	// SHOULD NOT auto-fix: nil guard dependency
	if obj != nil && obj.IsActive() {
		println("ok")
	}

	// SHOULD NOT auto-fix: error check must stay first
	if err != nil && err.Error() == "timeout" {
		println("err")
	}
}

type MyStruct struct{ active bool }

func (m *MyStruct) IsActive() bool { return m.active }
