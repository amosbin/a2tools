.PHONY: build clean install uninstall test

BINARY_NAME=a2cmds-mcp
INSTALL_PATH=/usr/local/bin

build:
	go mod tidy
	go build -o $(BINARY_NAME) .

clean:
	rm -f $(BINARY_NAME)

install: build
	sudo cp $(BINARY_NAME) $(INSTALL_PATH)/$(BINARY_NAME)
	sudo chmod 755 $(INSTALL_PATH)/$(BINARY_NAME)
	@echo "Installed $(BINARY_NAME) to $(INSTALL_PATH)"

uninstall:
	sudo rm -f $(INSTALL_PATH)/$(BINARY_NAME)
	@echo "Removed $(BINARY_NAME) from $(INSTALL_PATH)"

test:
	@echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}' | ./$(BINARY_NAME)
	@echo ""
	@echo '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | ./$(BINARY_NAME)
