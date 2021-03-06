# include root makefile
ifndef ROOT_MAKEFILE_MK
include ../../../../Makefile
endif

# prevent rules from being evaluated/included multiple times
ifndef $(abspath $(lastword $(MAKEFILE_LIST)))_MK
$(abspath $(lastword $(MAKEFILE_LIST)))_MK := 1


# The following are control variables that determine what logic from `rules.mk` is enabled

# `true`/`false` to enable/disable the actual unit test command so it can be overridden (the targets are still created)
# applies to both the pony and elixir test targets
$(abspath $(lastword $(MAKEFILE_LIST)))_UNIT_TEST_COMMAND := false

# `true`/`false` to enable/disable generate pony related targets (build/test/clean) for pony sources in this directory
# otherwise targets only get created if there are pony sources (*.pony) in this directory.
$(abspath $(lastword $(MAKEFILE_LIST)))_PONY_TARGET := true

# `true`/`false` to enable/disable generate final file build target using ponyc command for the pony build target so
# it can be overridden manually
$(abspath $(lastword $(MAKEFILE_LIST)))_PONYC_TARGET := true

# `true`/`false` to enable/disable generate exs related targets (build/test/clean) for elixir sources in this directory
# otherwise targets only get created if there are elixir sources (*.exs) in this directory.
$(abspath $(lastword $(MAKEFILE_LIST)))_EXS_TARGET := true

# `true`/`false` to enable/disable generate docker related targets (build/push) for a Dockerfile in this directory
# otherwise targets only get created if there is a Dockerfile in this directory
$(abspath $(lastword $(MAKEFILE_LIST)))_DOCKER_TARGET := true

# `true`/`false` to enable/disable recursing into Makefiles of subdirectories if they exist
# (and by recursion every makefile in the tree that is referenced)
$(abspath $(lastword $(MAKEFILE_LIST)))_RECURSE_SUBMAKEFILES := true


SEQUENCE_WINDOW_PATH := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

# standard rules generation makefile
include $(rules_mk_path)


build-testing-correctness-apps-sequence_window: build-testing-correctness-apps-sequence_window-validator

integration-tests-testing-correctness-apps-sequence_window: build-testing-correctness-apps-sequence_window

integration-tests-testing-correctness-apps-sequence_window: sequence_window_test

sequence_window_test:
	cd $(SEQUENCE_WINDOW_PATH) && \
	integration_test --sequence-sender '(0,1000]' \
	  --log-level error \
		--command './sequence_window' \
		--validation-cmd './validator/validator -e 1000 -a -i' \
		--output 'received.txt' \
		--giles-mode \
		--workers 2 \
		--batch-size 10 \
		--sink-expect 1000

clean-testing-correctness-apps-sequence_window: sequence_window_clean

sequence_window_clean:
	$(QUIET)rm -fr $(SEQUENCE_WINDOW_PATH)/sequence_window*

# end of prevent rules from being evaluated/included multiple times
endif
