PREFIX ?= $(HOME)/.local

build:
	swift build -c release

clean:
	swift package clean

install: build
	install -d $(PREFIX)/bin
	install .build/release/karabiner-hammerspoon-bridge $(PREFIX)/bin/

send-command:
	echo '{"action":"launcher"}' | socat - UNIX-SENDTO:"/Library/Application Support/org.pqrs/tmp/user/$(shell id -u)/user_command_receiver.sock"

swift-format:
	find Sources -name '*.swift' -print0 | xargs -0 swift-format --configuration '{ "spaces": 2 }' -i
