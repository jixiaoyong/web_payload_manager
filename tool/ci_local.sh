#!/usr/bin/env bash
#
# 本地原生 CI —— 直接使用本机的 Flutter / JDK / Android SDK / Xcode 与已有缓存。
# 不下载 SDK、不依赖网络，同一份脚本既能在终端手动跑，也被 ci.local.yml 调用。
#
# 仓库根目录由脚本自身位置推导，所以在开发副本和 runner workspace 里都能原地跑。
#
# 用法：
#   bash tool/ci_local.sh                     # 全量：分析 + 测试 + Android + iOS
#   SKIP_ANDROID=1 bash tool/ci_local.sh      # 跳过 APK
#   SKIP_IOS=1 bash tool/ci_local.sh          # 跳过 iOS 模拟器包
#   APK_MODE=debug bash tool/ci_local.sh      # 打 debug 包（默认 release）
#   ALL_ABIS=1 bash tool/ci_local.sh          # APK 打全部 ABI（默认只打 arm64）
#   CLEAN=1 bash tool/ci_local.sh             # 先 flutter clean 冷跑（增量状态坏掉时用）
#   KEEP_ARTIFACTS=10 bash tool/ci_local.sh   # 产物保留份数（默认 5）
#
set -euo pipefail

TOTAL_T0=$SECONDS

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

KEEP_ARTIFACTS="${KEEP_ARTIFACTS:-5}"
ART_ROOT="$REPO_ROOT/build/ci-artifacts"
STAMP="$(date +%Y%m%d-%H%M%S)"
ART_DIR="$ART_ROOT/$STAMP"
LOG_FILE="$ART_DIR/ci.log"
mkdir -p "$ART_DIR"

# 输出同时落盘，便于事后排查
exec > >(tee -a "$LOG_FILE") 2>&1

BOLD=$'\033[1m'; CYAN=$'\033[36m'; GREEN=$'\033[32m'; RED=$'\033[31m'; YELLOW=$'\033[33m'; RESET=$'\033[0m'

STEP_NAME="(初始化)"
STEP_T0=$SECONDS
SUMMARY=""

on_error() {
  printf "\n%s✘ 失败于步骤：%s%s\n" "$RED" "$STEP_NAME" "$RESET"
  printf "完整日志：%s\n" "$LOG_FILE"
  printf "%s若怀疑是增量/缓存状态损坏，可执行：CLEAN=1 bash tool/ci_local.sh%s\n" "$YELLOW" "$RESET"
}
trap on_error ERR

begin() { STEP_NAME="$1"; STEP_T0=$SECONDS; printf "\n%s▶ %s%s\n" "$CYAN" "$1" "$RESET"; }
end() {
  local d=$(( SECONDS - STEP_T0 ))
  SUMMARY="${SUMMARY}${STEP_NAME}|${d}s"$'\n'
  printf "%s✔ %s  %ss%s\n" "$GREEN" "$STEP_NAME" "$d" "$RESET"
}

coverage_summary() {
  if [ ! -f coverage/lcov.info ]; then
    return 0
  fi
  awk -F: '
    /^LF:/  { lf  += $2 }
    /^LH:/  { lh  += $2 }
    /^FNF:/ { fnf += $2 }
    /^FNH:/ { fnh += $2 }
    END {
      if (lf  > 0) printf "  行覆盖率   : %.1f%%  (%d/%d)\n",  lh  * 100 / lf,  lh,  lf
      if (fnf > 0) printf "  函数覆盖率 : %.1f%%  (%d/%d)\n",  fnh * 100 / fnf, fnh, fnf
    }' coverage/lcov.info
}

# 只保留最近 KEEP_ARTIFACTS 份产物；删除一律走废纸篓
prune_artifacts() {
  if [ ! -d "$ART_ROOT" ]; then
    return 0
  fi
  local count=0 d target
  for d in $(ls -1 "$ART_ROOT" 2>/dev/null | sort -r); do
    count=$(( count + 1 ))
    if [ "$count" -le "$KEEP_ARTIFACTS" ]; then
      continue
    fi
    target="$ART_ROOT/$d"
    if [ ! -d "$target" ]; then
      continue
    fi
    if command -v trash >/dev/null 2>&1; then
      trash "$target" >/dev/null 2>&1 || true
    else
      mv "$target" "$HOME/.Trash/ci-artifact-$d" 2>/dev/null || true
    fi
    printf "  已回收旧产物：%s\n" "$d"
  done
}

# ---------------------------------------------------------------- 0. 仓库状态
begin "Repo state"
printf "  commit : %s %s\n" "$(git rev-parse --short HEAD)" "$(git log -1 --pretty=%s)"
printf "  branch : %s\n" "$(git rev-parse --abbrev-ref HEAD)"
printf "  path   : %s\n" "$REPO_ROOT"
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  printf "%s  ⚠ 工作区有未提交改动（仅提示，不影响本次构建）%s\n" "$YELLOW" "$RESET"
fi
end

# ---------------------------------------------------------------- 1. 工具链
begin "Resolve local toolchain"

VER="$(sed -n 's/.*"flutter"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' .fvmrc 2>/dev/null)"
if [ -z "$VER" ]; then
  echo "无法从 .fvmrc 解析 Flutter 版本，请检查 .fvmrc"
  exit 1
fi

FLUTTER_SDK="${FVM_HOME:-$HOME/.fvm}/versions/$VER"
if [ ! -x "$FLUTTER_SDK/bin/flutter" ]; then
  echo "找不到 $FLUTTER_SDK/bin/flutter —— 请先执行 fvm install $VER"
  exit 1
fi

export FLUTTER_ROOT="$FLUTTER_SDK"
export PATH="$FLUTTER_SDK/bin:$PATH"
export FLUTTER_SUPPRESS_ANALYTICS=true
export CI=true

# Android SDK：local.properties > 环境变量 > macOS 标准默认路径
if [ -z "${ANDROID_SDK_ROOT:-}" ] && [ -f example/android/local.properties ]; then
  ANDROID_SDK_ROOT="$(sed -n 's/^sdk\.dir=//p' example/android/local.properties)"
fi
ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}"
export ANDROID_SDK_ROOT
export ANDROID_HOME="$ANDROID_SDK_ROOT"

# JDK：已有 JAVA_HOME > 系统默认 /usr/libexec/java_home
if [ -z "${JAVA_HOME:-}" ]; then
  JAVA_HOME="$(/usr/libexec/java_home 2>/dev/null || true)"
fi
if [ -z "${JAVA_HOME:-}" ]; then
  echo "未找到可用 JDK（Android 构建需要）"
  exit 1
fi
export JAVA_HOME

# 全部指向本机已有缓存，避免重复下载
export GRADLE_USER_HOME="${GRADLE_USER_HOME:-$HOME/.gradle}"
export PUB_CACHE="${PUB_CACHE:-$HOME/.pub-cache}"

# 版本断言直接读 SDK 自带的 flutter.version.json。
# 不执行 `flutter --version`：那个命令会触发 cache.updateAll，在共享的 ~/.fvm 里
# 删写 bin/cache/engine.stamp —— 每次 CI 都要动一次 SDK，既慢又制造共享可变状态。
VJSON="$FLUTTER_SDK/bin/cache/flutter.version.json"
FV_VER=""
DART_VER=""
CHANNEL="?"
if [ -f "$VJSON" ]; then
  FV_VER="$(sed -n 's/.*"frameworkVersion"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$VJSON")"
  DART_VER="$(sed -n 's/.*"dartSdkVersion"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$VJSON")"
  CHANNEL="$(sed -n 's/.*"channel"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$VJSON")"
elif [ -f "$FLUTTER_SDK/version" ]; then
  FV_VER="$(tr -d '[:space:]' < "$FLUTTER_SDK/version")"
fi
if [ "$FV_VER" != "$VER" ]; then
  echo "Flutter 版本不符：期望 $VER，实际为 '${FV_VER:-未知}'（$FLUTTER_SDK）"
  exit 1
fi

printf "  Flutter : %s (%s, dart %s)\n" "$FV_VER" "${CHANNEL:-?}" "${DART_VER:-?}"
printf "  SDK     : %s\n" "$FLUTTER_SDK"
printf "  Java    : %s\n" "$JAVA_HOME"
printf "  Android : %s\n" "$ANDROID_SDK_ROOT"
printf "  Xcode   : %s\n" "$(xcodebuild -version 2>/dev/null | head -1 || echo '未安装')"
printf "  Caches  : pub=%s gradle=%s\n" "$PUB_CACHE" "$GRADLE_USER_HOME"
end

# ---------------------------------------------------------------- 1.5 可选冷跑
if [ "${CLEAN:-0}" = "1" ]; then
  begin "Clean build state (CLEAN=1)"
  flutter clean >/dev/null 2>&1 || true
  ( cd example && flutter clean >/dev/null 2>&1 ) || true
  end
fi

# ---------------------------------------------------------------- 2. 根插件
begin "Install dependencies (Root Plugin)"
flutter pub get
end

begin "Analyze Root Plugin"
flutter analyze --no-fatal-infos
end

begin "Run Root Plugin Unit Tests"
flutter test --coverage
end

# ---------------------------------------------------------------- 3. Example
begin "Install dependencies (Example)"
( cd example && flutter pub get )
end

begin "Analyze Example"
( cd example && flutter analyze --no-fatal-infos )
end

begin "Run Example Widget Tests"
( cd example && flutter test )
end

# ---------------------------------------------------------------- 4. Android
# 默认打 release：AOT 编译、去掉 JIT 引擎与 kernel_blob，天然更小；而且 release
# 不打包 dev 依赖，插件注册表一旦过期会立刻编译失败 —— 正好当作守门检查。
# 注意：debug 包的 libflutter.so 对所有 ABI 各打一份，--target-platform 在 debug
# 下不生效，所以只有 release 才能真正裁到 arm64 单架构。
APK_MODE="${APK_MODE:-release}"
if [ "${SKIP_ANDROID:-0}" = "1" ]; then
  printf "\n%s已跳过 Android 构建（SKIP_ANDROID=1）%s\n" "$CYAN" "$RESET"
else
  ABI_FLAG=""
  ABI_NOTE="arm64"
  MODE_LABEL="Release"
  if [ "$APK_MODE" = "release" ]; then
    if [ "${ALL_ABIS:-0}" = "1" ]; then
      ABI_NOTE="all ABIs"
    else
      ABI_FLAG="--target-platform android-arm64"
    fi
  else
    # debug 必打全 ABI，标签如实写
    ABI_NOTE="all ABIs"
    MODE_LABEL="Debug"
  fi

  # 不要加 --no-pub：release 构建要按 release 模式重新生成插件注册表，否则
  # dev 依赖（integration_test）会残留在 GeneratedPluginRegistrant 里，
  # javac 报「package ... does not exist」直接编译失败。
  begin "Build Android ${MODE_LABEL} APK ($ABI_NOTE)"
  ( cd example && flutter build apk --"$APK_MODE" $ABI_FLAG )
  end
fi

# ---------------------------------------------------------------- 5. iOS
if [ "${SKIP_IOS:-0}" = "1" ]; then
  printf "\n%s已跳过 iOS 构建（SKIP_IOS=1）%s\n" "$CYAN" "$RESET"
else
  begin "Build iOS (Simulator, no codesign)"
  # 同样不加 --no-pub：Android 刚按 release 模式生成过注册表（不含 dev 依赖），
  # iOS 走 debug 模式，需要按自己的模式重新生成一次。
  ( cd example && flutter build ios --simulator --no-codesign )
  end
fi

# ---------------------------------------------------------------- 6. 归档
begin "Collect artifacts"
APK_SRC="example/build/app/outputs/flutter-apk/app-${APK_MODE}.apk"
if [ -f "$APK_SRC" ]; then
  cp -f "$APK_SRC" "$ART_DIR/app-${APK_MODE}.apk"
  printf "  APK     : %s  (%s)\n" "$(ls -lh "$ART_DIR/app-${APK_MODE}.apk" | awk '{print $5}')" "app-${APK_MODE}.apk"
fi
if [ -d example/build/ios/iphonesimulator/Runner.app ]; then
  ditto -c -k --sequesterRsrc --keepParent \
    example/build/ios/iphonesimulator/Runner.app \
    "$ART_DIR/Runner-ios-simulator.zip"
  printf "  iOS zip : %s\n" "$(ls -lh "$ART_DIR/Runner-ios-simulator.zip" | awk '{print $5}')"
fi
if [ -f coverage/lcov.info ]; then
  cp -f coverage/lcov.info "$ART_DIR/lcov.info"
  coverage_summary
fi
prune_artifacts
end

# ---------------------------------------------------------------- 汇总
printf "\n%s=== 本地 CI 全部通过 ===%s  总耗时 %ss\n" "$BOLD$GREEN" "$RESET" "$(( SECONDS - TOTAL_T0 ))"
printf "  %-42s %s\n" "步骤" "耗时"
printf "%s" "$SUMMARY" | while IFS='|' read -r name secs; do
  [ -n "$name" ] && printf "  %-42s %s\n" "$name" "$secs"
done
printf "\n产物目录：%s\n完整日志：%s\n" "$ART_DIR" "$LOG_FILE"
