# apple-vision-ocr — local OCR for macOS
PREFIX ?= $(HOME)/.local
APP_DIR = $(HOME)/Applications

.PHONY: all engine app install install-app test clean dist help

all: engine

help:
	@echo "make engine      编译 OCR 引擎到 bin/ocrvision"
	@echo "make install     安装命令 vision-ocr 到 $(PREFIX)/bin"
	@echo "make app         打包 VisionOCR.app 到 app/dist/"
	@echo "make install-app 打包并复制到 $(APP_DIR)"
	@echo "make test        运行单元测试"
	@echo "make clean       清理构建产物"

engine:
	@./scripts/build-engine.sh

install: engine
	@./scripts/install.sh

app:
	@cd app && ./build.sh

install-app: app
	@mkdir -p $(APP_DIR)
	@rm -rf $(APP_DIR)/VisionOCR.app
	@cp -R app/dist/VisionOCR.app $(APP_DIR)/
	@echo "installed: $(APP_DIR)/VisionOCR.app"

test:
	@python3 -m unittest discover -s tests -v

clean:
	@rm -rf bin app/dist app/*.iconset app/icon_1024.png
	@find . -name __pycache__ -type d -prune -exec rm -rf {} +

dist: clean test install-app
	@echo "release artifacts ready"
