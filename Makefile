.PHONY: check test

check:
	rex config check examples/init.lua
	rex config check tests/config.lua

test:
	rex do tests/run.lua
	rex do tests/bootstrap.lua
