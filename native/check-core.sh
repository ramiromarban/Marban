#!/bin/sh
set -eu
cd "$(dirname "$0")"
mkdir -p .build
swiftc -parse-as-library GuizadoTV/Core/Models.swift GuizadoTV/Core/LiveDirectory.swift GuizadoTV/Core/JavaScriptUnpacker.swift GuizadoTV/Core/AppStore.swift Tests/CoreChecks.swift -o .build/core-checks
.build/core-checks
