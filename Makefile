# applevision-ocr — local OCR for macOS
PREFIX ?= $(HOME)/.local
APP_DIR = $(HOME)/Applications

.PHONY: all engine app install install-app test showcase fixture-pdf clean dist help

all: engine

help:
	@echo "make engine      编译 OCR 引擎到 bin/ocrvision"
	@echo "make install     安装命令 applevision-ocr 到 $(PREFIX)/bin"
	@echo "make app         打包 AppleVisionOCR.app 到 app/dist/"
	@echo "make install-app 打包并复制到 $(APP_DIR)"
	@echo "make test        运行单元测试"
	@echo "make showcase    重新生成 README 顶部的「截图 → 文本」对比图"
	@echo "make fixture-pdf 把 tests/fixtures/showcase.png 包成单页 PDF 素材"
	@echo "make clean       清理构建产物"

engine:
	@./scripts/build-engine.sh

install: engine
	@./scripts/install.sh

app:
	@cd app && ./build.sh

install-app: app
	@mkdir -p $(APP_DIR)
	@rm -rf $(APP_DIR)/AppleVisionOCR.app
	@cp -R app/dist/AppleVisionOCR.app $(APP_DIR)/
	@echo "installed: $(APP_DIR)/AppleVisionOCR.app"

test:
	@PYTHONPATH=src python3 -m unittest discover -s tests -v

# 重新生成 README 顶部的对比图：先用本项目自己识别截图，再用 Swift 排版成左右对比。
showcase: engine
	@PYTHONPATH=src python3 -m applevision_ocr.cli tests/fixtures/showcase.png --no-vote -o /tmp/showcase.txt
	@swiftc -O scripts/make-showcase.swift -o bin/make-showcase
	@./bin/make-showcase tests/fixtures/showcase.png /tmp/showcase.txt docs/showcase.png

# PDF 素材：把 showcase.png（dd.png）包成单页 PDF，供截图与测试使用
fixture-pdf:
	@swiftc -O scripts/make-fixture-pdf.swift -o bin/make-fixture-pdf
	@./bin/make-fixture-pdf tests/fixtures/showcase.png tests/fixtures/showcase.pdf

clean:
	@rm -rf bin app/dist app/*.iconset app/icon_1024.png
	@find . -name __pycache__ -type d -prune -exec rm -rf {} +

dist: clean test install-app
	@echo "release artifacts ready"
